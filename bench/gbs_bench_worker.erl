-module(gbs_bench_worker).
-behaviour(gen_batch_server).
-export([init/1, handle_batch/2]).

init(Cfg) ->
    process_flag(message_queue_data, off_heap),
    {ok, Cfg}.

handle_batch(Batch, #{base_delay_us := Base,
                      us_per_mb     := UsMb,
                      payload_size  := PSize,
                      collector     := C} = St) ->
    {heap_size, HeapBefore} = erlang:process_info(self(), heap_size),
    BatchBytes = length(Batch) * PSize,
    DelayUs = Base + round(BatchBytes * UsMb / (1024 * 1024)),
    busy_wait_us(DelayUs),
    {heap_size, HeapAfter} = erlang:process_info(self(), heap_size),
    HeapWords = max(HeapBefore, HeapAfter),
    {garbage_collection_info, GcProps} =
        erlang:process_info(self(), garbage_collection_info),
    MinorGcs = proplists:get_value(minor_gcs, GcProps, 0),
    MajorGcs = proplists:get_value(major_gcs, GcProps, 0),
    GcStats = #{minor_gcs => MinorGcs,
                major_gcs => MajorGcs,
                max_heap  => HeapWords},
    C ! {batch, length(Batch), HeapWords},
    Actions = [{reply, From, {ok, GcStats}} || {call, From, _} <- Batch],
    {ok, Actions, St}.

%% Microsecond-precision busy-wait.  timer:sleep/1 only accepts integer
%% milliseconds, which truncates sub-ms variable costs to zero for small
%% batches.
busy_wait_us(Us) ->
    Target = erlang:monotonic_time(microsecond) + Us,
    busy_wait_until(Target).

busy_wait_until(Target) ->
    case erlang:monotonic_time(microsecond) >= Target of
        true  -> ok;
        false -> busy_wait_until(Target)
    end.
