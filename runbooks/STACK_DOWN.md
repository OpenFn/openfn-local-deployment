# Stack Down: fail over to the other stack

> Shape: **standalone** (`v0.standalone`). On a clustered deployment delete this
> runbook.

> ✏️ **Template.** Replace every `example.org` and every `10.0.0.x`. Delete
> anything that does not apply to this deployment rather than leaving it
> unanswered.

Uptime Kuma shows **OpenFn (public) Down** and the serving stack's own monitor
Down. Users and the source systems cannot reach OpenFn. Nothing moves by
itself: a person decides and runs three commands.

## Confirm it is the stack, not the path to it

From somewhere other than the proxy:

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://openfn.example.org/health_check   # the public address
curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.11:4000/health_check         # the serving stack directly
```

- Both fail: the stack is down. Continue below.
- The public address fails but the stack answers: the problem is the proxy or
  its network. Go to [PROXY_DOWN.md](PROXY_DOWN.md) instead.
- Both answer: the monitor's view is wrong (its own network). Check Kuma's host
  before anything else.

If you can reach the failed stack's server, `sudo /opt/openfn/bin/openfn-status`
and `sudo /opt/openfn/bin/openfn-logs lightning` say why. A quick fix there
(`openfn-restart`) may be faster than a failover; decide within a few minutes,
not an hour.

## Fail over

1. On the other stack's server (`10.0.0.12`):

   ```sh
   sudo /opt/openfn/bin/openfn-activate
   ```

   Starts Lightning and the worker, waits until both are healthy, writes
   `SERVING=yes`. About a minute. If it fails, `openfn-logs lightning` there.

2. On the proxy (`10.0.0.13`):

   ```sh
   sudo openfn-switch backup        # or: openfn-switch primary
   sudo openfn-switch status
   ```

   The switch refuses a target that does not answer `/health_check`. Traffic
   now goes to the other stack. The Kuma public monitor should return to Up
   within its interval.

3. Tell the project team and the client. `/var/log/openfn-proxy/switch.log` on
   the proxy has the time and the user.

4. On the failed stack, once it is reachable again:

   ```sh
   sudo /opt/openfn/bin/openfn-standby
   ```

   Stops Lightning and the worker there (PostgreSQL keeps running) and writes
   `SERVING=no`. Two stacks must never both serve: each would run every
   scheduled workflow.

## Afterwards

- Requests that reached the proxy while no stack answered were not stored by
  anything. Whether a source system re-sends them is that system's behaviour;
  ask the owners of OpenMRS and OpenELIS which records fell into the gap.
- Work done on the stack that is now serving stays in its database. Before any
  later switch back, `openfn-backup` there if the audit trail matters.
- To move production back to its usual stack once repaired: the same three
  commands the other way, during a quiet period. Or leave it where it is; the
  two stacks are equals.
- If the failed stack was down for a long time, re-seed it from the serving
  one before it serves again: `openfn-backup` on the serving stack, copy the
  file over, and on the parked stack (Lightning stopped) drop and recreate the
  database and `psql` the dump in. Both stacks carry the same encryption key,
  so every stored credential still decrypts.
