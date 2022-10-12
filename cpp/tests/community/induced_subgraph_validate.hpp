/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
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
 * See the License for the specific language governin_from_mtxg permissions and
 * limitations under the License.
 */

#pragma once

#include <optional>
#include <vector>

template <typename vertex_t, typename edge_t, typename weight_t>
void induced_subgraph_validate(
  std::vector<edge_t> const& h_offsets,
  std::vector<vertex_t> const& h_indices,
  std::optional<std::vector<weight_t>> const& h_weights,
  std::vector<size_t> const& h_subgraph_offsets,
  std::vector<vertex_t> const& h_subgraph_vertices,
  std::vector<vertex_t> const& h_cugraph_subgraph_edgelist_majors,
  std::vector<vertex_t> const& h_cugraph_subgraph_edgelist_minors,
  std::optional<std::vector<weight_t>> const& h_cugraph_subgraph_edgelist_weights,
  std::vector<size_t> const& h_cugraph_subgraph_edge_offsets);
