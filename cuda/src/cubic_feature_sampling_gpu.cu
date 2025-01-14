#include "cuda_utils.h"
#include <THC/THCAtomics.cuh>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <torch/extension.h>

#define CUDA_NUM_THREADS 512

// Computer the number of threads needed in GPU
inline int get_n_threads(int n)
{
    const int pow_2 = std::log(static_cast<float>(n)) / std::log(2.0);
    return max(min(1 << pow_2, CUDA_NUM_THREADS), 1);
}

__device__ int compute_index(int offset_x, int offset_y, int offset_z, int scale)
{
    return offset_x * scale * scale + offset_y * scale + offset_z;
}

template <typename scalar_t>
__global__ void cubic_feature_sampling_kernel(int scale, int neighborhood_size, int n_vertices,
                                              int n_pts, int n_cubic_channels,
                                              const scalar_t* __restrict__ ptcloud,
                                              const scalar_t* __restrict__ cubic_features,
                                              scalar_t* __restrict__ point_features,
                                              int* __restrict__ grid_pt_indexes)
{
    int batch_index = blockIdx.x;
    int index = threadIdx.x;
    int stride = blockDim.x;
    int cub_scale = scale * scale * scale;

    ptcloud += batch_index * n_pts * 3;
    cubic_features += batch_index * n_cubic_channels * cub_scale;
    point_features += batch_index * n_pts * n_vertices * n_cubic_channels;
    grid_pt_indexes += batch_index * n_pts * n_vertices;

    for (int i = index; i < n_pts; i += stride)
    {
        scalar_t pt_x = ptcloud[i * 3 + 0];
        scalar_t pt_y = ptcloud[i * 3 + 1];
        scalar_t pt_z = ptcloud[i * 3 + 2];

        int lower_x = std::floor(pt_x);
        int upper_x = std::ceil(pt_x);
        if (lower_x == upper_x)
        {
            upper_x += 1;
        }
        int lower_y = std::floor(pt_y);
        int upper_y = std::ceil(pt_y);
        if (lower_y == upper_y)
        {
            upper_y += 1;
        }
        int lower_z = std::floor(pt_z);
        int upper_z = std::ceil(pt_z);
        if (lower_z == upper_z)
        {
            upper_z += 1;
        }

        int ns = neighborhood_size - 1;
        int vertex_idx = 0;
        for (int j = lower_x - ns; j <= upper_x + ns; ++j)
        {
            for (int k = lower_y - ns; k <= upper_y + ns; ++k)
            {
                for (int m = lower_z - ns; m <= upper_z + ns; ++m)
                {
                    if (j < 0 || j >= scale || k < 0 || k >= scale || m < 0 || m >= scale)
                    {
                        // Ignore points lies out of the grid
                        grid_pt_indexes[i * n_vertices + vertex_idx++] = -1;
                    }
                    else
                    {
                        // Calcuating indexes for adjacent vertices
                        grid_pt_indexes[i * n_vertices + vertex_idx++] =
                            compute_index(j, k, m, scale);
                    }
                }
            }
        }

        // Gather Features
        for (int j = 0; j < n_vertices; ++j)
        {
            for (int k = 0; k < n_cubic_channels; ++k)
            {
                int vertex_idx = grid_pt_indexes[i * n_vertices + j];
                if (vertex_idx == -1)
                {
                    continue;
                }
                int feature_idx = i * n_vertices * n_cubic_channels + j * n_cubic_channels + k;
                scalar_t feature_val = cubic_features[k * cub_scale + vertex_idx];
                point_features[feature_idx] = feature_val;
            }
        }
    }
}

std::vector<torch::Tensor> cubic_feature_sampling_kernel_wrapper(int scale, int neighborhood_size,
                                                                 torch::Tensor ptcloud,
                                                                 torch::Tensor cubic_features,
                                                                 cudaStream_t stream)
{
    int batch_size = ptcloud.size(0);
    int n_pts = ptcloud.size(1);
    int n_cubic_channels = cubic_features.size(1);

    int n_vertices = std::pow(neighborhood_size * 2, 3);
    auto point_features = torch::zeros({batch_size, n_pts, n_vertices, n_cubic_channels},
                                       torch::CUDA(ptcloud.scalar_type()));
    auto grid_pt_indexes = torch::zeros({batch_size, n_pts, n_vertices}, torch::CUDA(torch::kInt));

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        ptcloud.scalar_type(), "cubic_feature_sampling_cuda",
        (
            [&]
            {
                cubic_feature_sampling_kernel<<<batch_size, get_n_threads(n_pts), 0, stream>>>(
                    scale, neighborhood_size, n_vertices, n_pts, n_cubic_channels,
                    ptcloud.data_ptr<scalar_t>(), cubic_features.data_ptr<scalar_t>(),
                    point_features.data_ptr<scalar_t>(), grid_pt_indexes.data_ptr<int>());
            }));

    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess)
    {
        printf("Error in cubic_feature_sampling_kernel_wrapper: %s\n", cudaGetErrorString(err));
    }
    return {point_features, grid_pt_indexes};
}

template <typename scalar_t>
__global__ void cubic_feature_sampling_grad_kernel(int scale, int neighborhood_size, int n_vertices,
                                                   int n_pts, int n_cubic_channels,
                                                   const scalar_t* __restrict__ grad_point_features,
                                                   const int* __restrict__ grid_pt_indexes,
                                                   scalar_t* __restrict__ grad_ptcloud,
                                                   scalar_t* __restrict__ grad_cubic_features)
{
    int batch_index = blockIdx.x;
    int index = threadIdx.x;
    int stride = blockDim.x;
    int cub_scale = scale * scale * scale;

    grad_point_features += batch_index * n_pts * n_vertices * n_cubic_channels;
    grid_pt_indexes += batch_index * n_pts * n_vertices;
    grad_ptcloud += batch_index * n_pts * 3;
    grad_cubic_features += batch_index * n_cubic_channels * cub_scale;

    for (int i = index; i < n_pts; i += stride)
    {
        for (int j = 0; j < n_vertices; ++j)
        {
            int vertex_idx = grid_pt_indexes[i * n_vertices + j];
            if (vertex_idx == -1)
            {
                continue;
            }
            for (int k = 0; k < n_cubic_channels; ++k)
            {
                int grad_idx = i * n_vertices * n_cubic_channels + j * n_cubic_channels + k;
                scalar_t grad_val = grad_point_features[grad_idx];
                // Fix bugs: the gradients of ceil and floor functions are zeros.
                // Ref: https://github.com/tensorflow/tensorflow/issues/897
                // atomicAdd(&(grad_ptcloud[i * 3 + 0]), grad_val);
                // atomicAdd(&(grad_ptcloud[i * 3 + 1]), grad_val);
                // atomicAdd(&(grad_ptcloud[i * 3 + 2]), grad_val);
                gpuAtomicAdd(&(grad_cubic_features[k * cub_scale + vertex_idx]), grad_val);
            }
        }
    }
}

std::vector<torch::Tensor>
cubic_feature_sampling_grad_kernel_wrapper(int scale, int neighborhood_size,
                                           torch::Tensor grad_point_features,
                                           torch::Tensor grid_pt_indexes, cudaStream_t stream)
{
    int batch_size = grad_point_features.size(0);
    int n_cubic_channels = grad_point_features.size(3);
    int n_pts = grid_pt_indexes.size(1);
    int n_vertices = std::pow(neighborhood_size * 2, 3);

    auto grad_ptcloud =
        torch::zeros({batch_size, n_pts, 3}, torch::CUDA(grad_point_features.scalar_type()));
    auto grad_cubic_features = torch::zeros({batch_size, n_cubic_channels, scale, scale, scale},
                                            torch::CUDA(grad_point_features.scalar_type()));

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        grad_point_features.scalar_type(), "cubic_feature_sampling_grad_cuda",
        (
            [&]
            {
                cubic_feature_sampling_grad_kernel<<<batch_size, get_n_threads(n_pts), 0, stream>>>(
                    scale, neighborhood_size, n_vertices, n_pts, n_cubic_channels,
                    grad_point_features.data_ptr<scalar_t>(), grid_pt_indexes.data_ptr<int>(),
                    grad_ptcloud.data_ptr<scalar_t>(), grad_cubic_features.data_ptr<scalar_t>());
            }));

    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess)
    {
        printf("Error in cubic_feature_sampling_grad_kernel_wrapper: %s\n",
               cudaGetErrorString(err));
    }
    return {grad_ptcloud, grad_cubic_features};
}
