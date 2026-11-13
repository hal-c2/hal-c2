# The jobs of a CI run that failed or timed out, as [{name, id, url}]. A timeout ends a job
# cancelled, like the stop jobs' own cancel, but before any stop job started (or with none
# started, which a wedge that starves the stop job too can cause). A matrix cancels the
# rest of its entries when one fails, so a cancel beside a failure in the same matrix is
# not a timeout. Input: the run's jobs listing.
def matrix: .name | sub(" \\(.*$"; "");
def stop: .name | startswith("Stop the queue run") or . == "CI result";
([.jobs[] | select(.name | startswith("Stop the queue run")) | select(.started_at and .conclusion != "skipped")
  | .started_at] | min) as $stopped
| [.jobs[] | select(.conclusion == "failure" and (stop | not)) | matrix] as $failed
| [.jobs[] | select(stop | not)
   | select(.conclusion == "failure"
            or (.conclusion == "cancelled" and .completed_at < ($stopped // "9999")
                and (matrix as $m | $failed | index($m) | not)))
   | {name, id, url: .html_url, timed_out: (.conclusion == "cancelled")}]
| unique_by(.name)
