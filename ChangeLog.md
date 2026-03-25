# Change Log

## Changes Between 0.9.2 and 0.10.0 (in development)

(no changes yet)

## Changes Between 0.9.1 and 0.9.2 (Mar 25, 2026)

### Bug Fixes

 * Erlang process mailbox is now flushed before exiting to prevent OOM events during crash report formatting
   done by parts of Erlang/OTP
 * Strip function arguments from stacktrace to prevent the same OOM events during crash report formatting

## Changes Between 0.8.4 and 0.9.0

### Enhancements

 * Updated `init_it` to match modern `gen_server:init_it` behavior
 * Reduced delta with `gen_server` further, refactored internals
 * Use `try catch` which is better optimized by modern Erlang's JIT

 ### Bug Fixes

 * Enforce `rebar3_hex` 7.0+ for Erlang 26+ compatibility

### Minimum Supported Erlang Version Bump

The library now requires OTP 26+.

## Changes Between 0.8.3 and 0.8.4 (July 20th, 2020)

### License Change

The library is now double-licensed under the Apache Software License 2.0
and Mozilla Public License 2.0 (previously: under the ASL2 and Mozilla Public License 1.1).

### Minimum Supported Erlang Version Bump

The library now requires OTP 21.3 or a later version.
