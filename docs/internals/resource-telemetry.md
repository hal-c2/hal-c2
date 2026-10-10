# Resource telemetry

The MC samples the process tree under itself with `ps`
([`HalC2.Diagnostics`](../../apps/server-ex/lib/hal_c2/diagnostics.ex)): every 15 seconds, or
every 2 while a client watches the resource monitor, keeping an hour of samples. There is no
telemetry database, no native collector and no recurring shell-probe fallback, and a failed read
leaves the MC running. Host power state is unknown, since no desktop host supplies it.

## Collection cost

Sampling runs faster only while diagnostics has a live subscriber, and history is read on demand.
Anything that wants the process list for background scheduling must not retain a live
subscription.

## Measurement traps

- Process identity includes start time because operating systems reuse PIDs.
  `server.signalProcess` signals a process only when it is still the one the client saw.
- Sampling can miss a process that starts and exits between samples. Cumulative
  counters still yield deltas for processes observed across samples.
- Unix counters report storage I/O (`/proc/<pid>/io`, Linux only), which can differ from logical
  application reads and writes because of OS caching. The MC's own logical I/O by operation is
  kept separately ([`HalC2.Diagnostics.Attribution`](../../apps/server-ex/lib/hal_c2/diagnostics/attribution.ex)).
  Keep the two apart.
- Group totals accumulate observed deltas since telemetry started. Per-process
  cumulative counters cover the operating system's lifetime for that process.
