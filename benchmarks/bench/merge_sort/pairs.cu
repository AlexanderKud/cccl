#include <cub/device/device_merge_sort.cuh>

#include <nvbench_helper.cuh>

// %RANGE% TUNE_TRANSPOSE trp 0:1:1
// %RANGE% TUNE_LOAD ld 0:2:1
// %RANGE% TUNE_ITEMS_PER_THREAD ipt 7:24:1
// %RANGE% TUNE_THREADS_PER_BLOCK_POW2 tpb 6:10:1

#ifndef TUNE_BASE
#define TUNE_THREADS_PER_BLOCK (1 << TUNE_THREADS_PER_BLOCK_POW2)
#endif

#if !TUNE_BASE
#if TUNE_TRANSPOSE == 0
#define TUNE_LOAD_ALGORITHM cub::BLOCK_LOAD_DIRECT
#define TUNE_STORE_ALGORITHM cub::BLOCK_STORE_DIRECT
#else
#define TUNE_LOAD_ALGORITHM cub::BLOCK_LOAD_WARP_TRANSPOSE
#define TUNE_STORE_ALGORITHM cub::BLOCK_STORE_WARP_TRANSPOSE
#endif

#if TUNE_LOAD == 0
#define TUNE_LOAD_MODIFIER cub::LOAD_DEFAULT
#elif TUNE_LOAD == 1
#define TUNE_LOAD_MODIFIER cub::LOAD_LDG
#else
#define TUNE_LOAD_MODIFIER cub::LOAD_CA
#endif

template <typename KeyT>
struct policy_hub_t
{
  struct policy_t : cub::ChainedPolicy<300, policy_t, policy_t>
  {
    using MergeSortPolicy =
      cub::AgentMergeSortPolicy<TUNE_THREADS_PER_BLOCK,
                                cub::Nominal4BItemsToItems<KeyT>(TUNE_ITEMS_PER_THREAD),
                                TUNE_LOAD_ALGORITHM,
                                TUNE_LOAD_MODIFIER,
                                TUNE_STORE_ALGORITHM>;
  };

  using MaxPolicy = policy_t;
};
#endif

template <typename KeyT, typename ValueT, typename OffsetT>
void merge_sort_keys(nvbench::state &state, nvbench::type_list<KeyT, ValueT, OffsetT>)
{
  using key_t            = KeyT;
  using value_t          = ValueT;
  using key_input_it_t   = key_t *;
  using value_input_it_t = value_t *;
  using key_it_t         = key_t *;
  using value_it_t       = value_t *;
  using offset_t         = OffsetT;
  using compare_op_t     = less_t;

#if !TUNE_BASE
  using policy_t   = policy_hub_t<key_t>;
  using dispatch_t = cub::DispatchMergeSort<key_input_it_t,
                                            value_input_it_t,
                                            key_it_t,
                                            value_it_t,
                                            offset_t,
                                            compare_op_t,
                                            policy_t>;
#else
  using dispatch_t = cub::
    DispatchMergeSort<key_input_it_t, value_input_it_t, key_it_t, value_it_t, offset_t, compare_op_t>;
#endif

  // Retrieve axis parameters
  const auto elements       = static_cast<std::size_t>(state.get_int64("Elements{io}"));
  const bit_entropy entropy = str_to_entropy(state.get_string("Entropy"));

  thrust::device_vector<key_t> keys_buffer_1(elements);
  thrust::device_vector<key_t> keys_buffer_2(elements);
  thrust::device_vector<value_t> values_buffer_1(elements);
  thrust::device_vector<value_t> values_buffer_2(elements);

  gen(seed_t{}, keys_buffer_1);

  key_t *d_keys_buffer_1   = thrust::raw_pointer_cast(keys_buffer_1.data());
  key_t *d_keys_buffer_2   = thrust::raw_pointer_cast(keys_buffer_2.data());
  value_t *d_values_buffer_1 = thrust::raw_pointer_cast(values_buffer_1.data());
  value_t *d_values_buffer_2 = thrust::raw_pointer_cast(values_buffer_2.data());

  // Enable throughput calculations and add "Size" column to results.
  state.add_element_count(elements);
  state.add_global_memory_reads<KeyT>(elements);
  state.add_global_memory_reads<ValueT>(elements);
  state.add_global_memory_writes<KeyT>(elements);
  state.add_global_memory_writes<ValueT>(elements);

  // Allocate temporary storage:
  std::size_t temp_size{};
  dispatch_t::Dispatch(nullptr,
                       temp_size,
                       d_keys_buffer_1,
                       d_values_buffer_1,
                       d_keys_buffer_2,
                       d_values_buffer_2,
                       static_cast<offset_t>(elements),
                       compare_op_t{},
                       0 /* stream */);

  thrust::device_vector<nvbench::uint8_t> temp(temp_size);
  auto *temp_storage = thrust::raw_pointer_cast(temp.data());

  state.exec([&](nvbench::launch &launch) {
    dispatch_t::Dispatch(temp_storage,
                         temp_size,
                         d_keys_buffer_1,
                         d_values_buffer_1,
                         d_keys_buffer_2,
                         d_values_buffer_2,
                         static_cast<offset_t>(elements),
                         compare_op_t{},
                         launch.get_stream());
  });
}

#ifdef TUNE_KeyT
using key_types = nvbench::type_list<TUNE_KeyT>;
#else
using key_types = all_types;
#endif

#ifdef TUNE_ValueT
using value_types = nvbench::type_list<TUNE_ValueT>;
#else
using value_types = nvbench::type_list<int8_t, int16_t, int32_t, int64_t, int128_t>;
#endif

NVBENCH_BENCH_TYPES(merge_sort_keys, NVBENCH_TYPE_AXES(key_types, value_types, offset_types))
  .set_name("cub::DeviceMergeSort::SortPairs")
  .set_type_axes_names({"KeyT{ct}", "ValueT{ct}", "OffsetT{ct}"})
  .add_int64_power_of_two_axis("Elements{io}", nvbench::range(16, 28, 4))
  .add_string_axis("Entropy", {"1.000", "0.201"});
