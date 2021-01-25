/*
 * Copyright (c) 2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <experimental/graph_functions.hpp>
#include <experimental/graph_view.hpp>
#include <matrix_partition_device.cuh>
#include <utilities/error.hpp>
#include <vertex_partition_device.cuh>

#include <rmm/thrust_rmm_allocator.h>
#include <raft/handle.hpp>
#include <rmm/device_uvector.hpp>

#include <thrust/binary_search.h>
#include <thrust/copy.h>
#include <thrust/gather.h>
#include <thrust/sort.h>
#include <thrust/tuple.h>

#include <tuple>

namespace cugraph {
namespace experimental {

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>,
           rmm::device_uvector<vertex_t>,
           rmm::device_uvector<weight_t>,
           rmm::device_uvector<size_t>>
extract_induced_subgraphs(
  raft::handle_t const &handle,
  graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu> const &graph_view,
  size_t const *subgraph_offsets /* size == num_subgraphs + 1 */,
  vertex_t const *subgraph_vertices /* size == subgraph_offsets[num_subgraphs] */,
  size_t num_subgraphs,
  bool do_expensive_check)
{
  // FIXME: this code is inefficient for the vertices with their local degrees much larger than the
  // number of vertices in the subgraphs (in this case, searching that the subgraph vertices are
  // included in the local neighbors is more efficient than searching the local neighbors are
  // included in the subgraph vertices). We may later add additional code to handle such cases.
  // FIXME: we may consider the performance (speed & memory footprint, hash based approach uses
  // extra-memory) of hash table based and binary search based approaches

  // 1. check input arguments

  if (do_expensive_check) {
    size_t should_be_zero{std::numeric_limits<size_t>::max()};
    size_t num_aggregate_subgraph_vertices{};
    raft::update_host(&should_be_zero, subgraph_offsets, 1, handle.get_stream());
    raft::update_host(
      &num_aggregate_subgraph_vertices, subgraph_offsets + num_subgraphs, 1, handle.get_stream());
    CUDA_TRY(cudaStreamSynchronize(handle.get_stream()));
    CUGRAPH_EXPECTS(should_be_zero == 0,
                    "Invalid input argument: subgraph_offsets[0] should be 0.");

    CUGRAPH_EXPECTS(
      thrust::is_sorted(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                        subgraph_offsets,
                        subgraph_offsets + (num_subgraphs + 1)),
      "Invalid input argument: subgraph_offsets is not sorted.");
    vertex_partition_device_t<graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>>
      vertex_partition(graph_view);
    CUGRAPH_EXPECTS(thrust::count_if(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                                     subgraph_vertices,
                                     subgraph_vertices + num_aggregate_subgraph_vertices,
                                     [vertex_partition] __device__(auto v) {
                                       return !vertex_partition.is_valid_vertex(v) ||
                                              !vertex_partition.is_local_vertex_nocheck(v);
                                     }) == 0,
                    "Invalid input argument: subgraph_vertices has invalid vertex IDs.");

    CUGRAPH_EXPECTS(
      thrust::count_if(
        rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
        thrust::make_counting_iterator(size_t{0}),
        thrust::make_counting_iterator(num_subgraphs),
        [subgraph_offsets, subgraph_vertices] __device__(auto i) {
          // vertices are sorted and unique
          return !thrust::is_sorted(thrust::seq,
                                    subgraph_vertices + subgraph_offsets[i],
                                    subgraph_vertices + subgraph_offsets[i + 1]) ||
                 (thrust::count_if(
                    thrust::seq,
                    thrust::make_counting_iterator(subgraph_offsets[i]),
                    thrust::make_counting_iterator(subgraph_offsets[i + 1]),
                    [subgraph_vertices, last = subgraph_offsets[i + 1] - 1] __device__(auto i) {
                      return (i != last) && (subgraph_vertices[i] == subgraph_vertices[i + 1]);
                    }) != 0);
        }) == 0,
      "Invalid input argument: subgraph_vertices for each subgraph idx should be sorted in "
      "ascending order and unique.");
  }

  // 2. extract induced subgraphs

  if (multi_gpu) {
    CUGRAPH_FAIL("Unimplemented.");
    return std::make_tuple(rmm::device_uvector<vertex_t>(0, handle.get_stream()),
                           rmm::device_uvector<vertex_t>(0, handle.get_stream()),
                           rmm::device_uvector<weight_t>(0, handle.get_stream()),
                           rmm::device_uvector<size_t>(0, handle.get_stream()));
  } else {
    // 2-1. Phase 1: calculate memory requirements

    size_t num_aggregate_subgraph_vertices{};
    raft::update_host(
      &num_aggregate_subgraph_vertices, subgraph_offsets + num_subgraphs, 1, handle.get_stream());
    CUDA_TRY(cudaStreamSynchronize(handle.get_stream()));

    rmm::device_uvector<size_t> subgraph_vertex_output_offsets(
      num_aggregate_subgraph_vertices + 1,
      handle.get_stream());  // for each element of subgraph_vertices

    matrix_partition_device_t<graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>>
      matrix_partition(graph_view, 0);
    // count the numbers of the induced subgraph edges for each vertex in the aggregate subgraph
    // vertex list.
    thrust::transform(
      rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
      thrust::make_counting_iterator(size_t{0}),
      thrust::make_counting_iterator(num_aggregate_subgraph_vertices),
      subgraph_vertex_output_offsets.begin(),
      [subgraph_offsets, subgraph_vertices, num_subgraphs, matrix_partition] __device__(auto i) {
        auto subgraph_idx = thrust::distance(
          subgraph_offsets + 1,
          thrust::upper_bound(thrust::seq, subgraph_offsets, subgraph_offsets + num_subgraphs, i));
        vertex_t const *indices{nullptr};
        weight_t const *weights{nullptr};
        edge_t local_degree{};
        auto major_offset =
          matrix_partition.get_major_offset_from_major_nocheck(subgraph_vertices[i]);
        thrust::tie(indices, weights, local_degree) =
          matrix_partition.get_local_edges(major_offset);
        // FIXME: this is inefficient for high local degree vertices
        return thrust::count_if(
          thrust::seq,
          indices,
          indices + local_degree,
          [vertex_first = subgraph_vertices + subgraph_offsets[subgraph_idx],
           vertex_last =
             subgraph_vertices + subgraph_offsets[subgraph_idx + 1]] __device__(auto nbr) {
            return thrust::binary_search(thrust::seq, vertex_first, vertex_last, nbr);
          });
      });
    thrust::exclusive_scan(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                           subgraph_vertex_output_offsets.begin(),
                           subgraph_vertex_output_offsets.end(),
                           subgraph_vertex_output_offsets.begin());

    size_t num_aggregate_edges{};
    raft::update_host(&num_aggregate_edges,
                      subgraph_vertex_output_offsets.data() + num_aggregate_subgraph_vertices,
                      1,
                      handle.get_stream());
    CUDA_TRY(cudaStreamSynchronize(handle.get_stream()));

    // 2-2. Phase 2: find the edges in the induced subgraphs

    rmm::device_uvector<vertex_t> edge_majors(num_aggregate_edges, handle.get_stream());
    rmm::device_uvector<vertex_t> edge_minors(num_aggregate_edges, handle.get_stream());
    rmm::device_uvector<weight_t> edge_weights(
      graph_view.is_weighted() ? num_aggregate_edges : size_t{0}, handle.get_stream());

    // fill the edge list buffer (to be returned) for each vetex in the aggregate subgraph vertex
    // list (use the offsets computed in the Phase 1)
    thrust::for_each(
      rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
      thrust::make_counting_iterator(size_t{0}),
      thrust::make_counting_iterator(num_aggregate_subgraph_vertices),
      [subgraph_offsets,
       subgraph_vertices,
       num_subgraphs,
       matrix_partition,
       subgraph_vertex_output_offsets = subgraph_vertex_output_offsets.data(),
       edge_majors                    = edge_majors.data(),
       edge_minors                    = edge_minors.data(),
       edge_weights                   = edge_weights.data()] __device__(auto i) {
        auto subgraph_idx = thrust::distance(
          subgraph_offsets + 1,
          thrust::upper_bound(
            thrust::seq, subgraph_offsets, subgraph_offsets + num_subgraphs, size_t{i}));
        vertex_t const *indices{nullptr};
        weight_t const *weights{nullptr};
        edge_t local_degree{};
        auto major_offset =
          matrix_partition.get_major_offset_from_major_nocheck(subgraph_vertices[i]);
        thrust::tie(indices, weights, local_degree) =
          matrix_partition.get_local_edges(major_offset);
        if (weights != nullptr) {
          auto triplet_first = thrust::make_zip_iterator(thrust::make_tuple(
            thrust::make_constant_iterator(subgraph_vertices[i]), indices, weights));
          // FIXME: this is inefficient for high local degree vertices
          thrust::copy_if(
            thrust::seq,
            triplet_first,
            triplet_first + local_degree,
            thrust::make_zip_iterator(thrust::make_tuple(edge_majors, edge_minors, edge_weights)) +
              subgraph_vertex_output_offsets[i],
            [vertex_first = subgraph_vertices + subgraph_offsets[subgraph_idx],
             vertex_last =
               subgraph_vertices + subgraph_offsets[subgraph_idx + 1]] __device__(auto t) {
              return thrust::binary_search(
                thrust::seq, vertex_first, vertex_last, thrust::get<1>(t));
            });
        } else {
          auto pair_first = thrust::make_zip_iterator(
            thrust::make_tuple(thrust::make_constant_iterator(subgraph_vertices[i]), indices));
          // FIXME: this is inefficient for high local degree vertices
          thrust::copy_if(thrust::seq,
                          pair_first,
                          pair_first + local_degree,
                          thrust::make_zip_iterator(thrust::make_tuple(edge_majors, edge_minors)) +
                            subgraph_vertex_output_offsets[i],
                          [vertex_first = subgraph_vertices + subgraph_offsets[subgraph_idx],
                           vertex_last  = subgraph_vertices +
                                         subgraph_offsets[subgraph_idx + 1]] __device__(auto t) {
                            return thrust::binary_search(
                              thrust::seq, vertex_first, vertex_last, thrust::get<1>(t));
                          });
        }
      });

    rmm::device_uvector<size_t> subgraph_edge_offsets(num_subgraphs + 1, handle.get_stream());
    thrust::gather(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                   subgraph_offsets,
                   subgraph_offsets + (num_subgraphs + 1),
                   subgraph_vertex_output_offsets.begin(),
                   subgraph_edge_offsets.begin());

    return std::make_tuple(std::move(edge_majors),
                           std::move(edge_minors),
                           std::move(edge_weights),
                           std::move(subgraph_edge_offsets));
  }
}

// explicit instantiation

template std::tuple<rmm::device_uvector<int32_t>,
                    rmm::device_uvector<int32_t>,
                    rmm::device_uvector<float>,
                    rmm::device_uvector<size_t>>
extract_induced_subgraphs(raft::handle_t const &handle,
                          graph_view_t<int32_t, int32_t, float, true, false> const &graph_view,
                          size_t const *subgraph_offsets,
                          int32_t const *subgraph_vertices,
                          size_t num_subgraphs,
                          bool do_expensive_check);

template std::tuple<rmm::device_uvector<int32_t>,
                    rmm::device_uvector<int32_t>,
                    rmm::device_uvector<float>,
                    rmm::device_uvector<size_t>>
extract_induced_subgraphs(raft::handle_t const &handle,
                          graph_view_t<int32_t, int32_t, float, false, false> const &graph_view,
                          size_t const *subgraph_offsets,
                          int32_t const *subgraph_vertices,
                          size_t num_subgraphs,
                          bool do_expensive_check);

}  // namespace experimental
}  // namespace cugraph
