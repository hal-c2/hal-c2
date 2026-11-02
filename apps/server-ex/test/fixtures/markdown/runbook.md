# Runbook: a stuck kitchen screen

> The screen shows orders from the last poll only.
> If it stops, orders still reach the printer.
>
> Check the printer before paging anyone.

1. Open the admin console.
2. Find the station:
   ```sh
   mise run stations --stuck
   ```
3. Restart it.
   - If it comes back, close the incident.
   - If not:
     1. Page the on-call.
     2. Note the time.

3) Numbered from three, with a paren.
4) And on.

+ A plus-sign list
+ that a linter left alone

* * *

Escalate after 15 minutes.
