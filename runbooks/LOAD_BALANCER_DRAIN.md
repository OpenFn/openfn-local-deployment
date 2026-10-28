# Connecting OpenFn to the Cloudflare load balancer

> Shape: **clustered** (`v0.ansible`). On a standalone deployment delete this
> runbook; its alerts come from Grafana, which that shape does not run.

> ✏️ **Template.** Replace every `example.org`, every `10.0.0.x`, and every
> `COUNTRY-openfn-deployment` before this goes to a client. Delete anything
> that does not apply to this deployment rather than leaving it unanswered.
For the client's infrastructure team. Set this up once and every future restart or
version update takes the server out of the load balancer first, waits for
traffic to move to the other server, and puts it back when it is healthy again.

**The API token stays with the client.** It is written to a file on the client's own servers
and read only by the script already installed there. It is never sent to OpenFn
and never leaves your infrastructure.

## Why it is worth doing

Both application servers serve traffic through the Cloudflare load balancer.
When one restarts it stops answering for about a minute.

Each server sits in its own pool: app-vm-01 in `pool-primary`, app-vm-02 in
`pool-secondary`, with the traffic split evenly between the two pools. That shape
matters for every command below, because each server's script reads only its own
pool and cannot see the other server.

Cloudflare only notices through its health check, which runs on a timer. In the
gap between the server stopping and the check noticing, Cloudflare keeps sending
people to it and those requests fail. This is the brief error seen during the
failover test on 22 September.

Once this is configured, that gap disappears. Nothing else about how you run the
servers changes.

## What you need first

**1. An API token.** In the Cloudflare dashboard, create a token with one
permission and nothing else:

```
Account | Load Balancing: Monitors and Pools | Edit
```

This token can change which servers are in a load balancer pool. It cannot read
or change DNS, it cannot see traffic, and it cannot touch anything else in the
account.

**2. Your account ID.** On the Cloudflare dashboard overview page for the
account.

**3. The pool ID, for each server.** Open Traffic, then Load Balancing, then
the load balancer for `openfn.example.org`. It uses two pools, one per server.
Open each in turn; the ID is in the URL and on the pool's own page. app-vm-01's
pool is `pool-primary` and app-vm-02's is `pool-secondary`.

**4. The endpoint name inside each pool.** The server appears in its pool under
a name. Note exactly how it is spelled. It must match what you put in the file
below; the script refuses to run if it does not, which is deliberate.

**5. The session affinity drain duration**, on each pool.

- 60 seconds or more: nothing to change.
- 0: sessions already attached to a server are dropped the instant it leaves the
  pool, rather than being allowed to finish. Setting it to 60 is worth doing.

## Install it on each server

On **each** application server, create `/opt/openfn/cf-lb.env`:

```bash
sudo install -m 600 /dev/null /opt/openfn/cf-lb.env
sudo nano /opt/openfn/cf-lb.env
```

```
CF_ACCOUNT_ID=<your account id>
CF_POOL_ID=<the pool id>
CF_API_TOKEN=<the token>
CF_ORIGIN_NAME=<this server's endpoint name in the pool>
CF_DRAIN_SECONDS=60
```

Two of those lines differ between the servers: `CF_POOL_ID`, because each server
is in its own pool, and `CF_ORIGIN_NAME`, which is that server's endpoint name
inside it. Getting `CF_POOL_ID` wrong points a server at the other one's pool, so
check it against the pool page before saving.

Mode `600` matters: the file holds the token, so only root should be able to
read it.

Nothing needs restarting. The script picks the file up the next time it runs.

## Check it works

On each server:

```bash
/opt/openfn/bin/openfn-lb-drain status
```

It should list that server's own endpoint with `enabled=True`, and only that
one. Run it on both servers to see both. If it says `no /opt/openfn/cf-lb.env`,
the file is missing or unreadable. If it says there is no endpoint by that name,
`CF_ORIGIN_NAME` does not match the pool.

Then try one server, with the site open in a browser:

```bash
/opt/openfn/bin/openfn-lb-drain out    # takes this server out, waits for the drain
/opt/openfn/bin/openfn-lb-drain status # this one now shows enabled=False
/opt/openfn/bin/openfn-lb-drain in     # back in
```

The site keeps working throughout, because the other server carries it.

## What changes afterwards

Nothing to remember and nothing extra to run. `openfn-restart` and
`openfn-update` already call the drain themselves:

```
openfn-lb-drain out   ->   restart   ->   openfn-lb-drain in
```

The "back in" step runs even if the restart fails, because it is a shell trap on
exit rather than a final line in the script. A server cannot be left out of the
pool because something went wrong halfway.

## Has this been tested

Yes, on a matching two-server deployment behind a real Cloudflare load balancer,
measured by requesting the public address once a second throughout.

**Planned restart, with the drain.** One server restarted with
`openfn-restart`. 198 requests, every one answered normally, **none failed**.

**The same loss, without warning.** Lightning stopped on one server and left
down, which is what a crash looks like to Cloudflare.

```
t+10   Lightning stops
t+15   first failed request
t+50   last failed request
t+51   onwards, clean, all traffic now on the healthy server
```

**23 requests failed, over a window of about 40 seconds.** That is how long
Cloudflare's health monitor took to decide the server was gone. During it,
roughly half of all requests failed, because Cloudflare was still splitting
traffic between the two servers and one was answering errors.

| | Failed requests | Window |
|---|---|---|
| Planned restart, with the drain | 0 of 198 | none |
| Server lost without warning | 23 | about 40 seconds |

An update without the drain behaves exactly like a crash: around 40 seconds of
errors for about half of users, for each server, so roughly 80 seconds across a
two-server update. With the drain, none.

The health monitor still matters. It is what catches a genuine crash, a lost
host or a severed network, where nothing gets the chance to announce anything.
The drain only removes the delay for stops that are planned. If 40 seconds is
too long for unplanned failures, that is the monitor's interval and retry count
on the pool, and it can be tuned separately from everything here.

A third run was interrupted on purpose, killing the restart partway through. The
server still returned to the pool by itself, because the step that puts it back
is a shell trap on exit rather than the last line of the script. Nothing was left
stranded outside the load balancer.

## Running it by hand from your own machine

The script lives on the servers, so reach it over SSH. There is nothing to
install on a laptop:

```bash
ssh <you>@10.0.0.11 sudo /opt/openfn/bin/openfn-lb-drain status   # app-vm-01
ssh <you>@10.0.0.12 sudo /opt/openfn/bin/openfn-lb-drain status   # app-vm-02
```

Each one reports its own pool, so to see the whole picture ask both. The
Cloudflare dashboard shows both pools on one page, which is often quicker.

## If you would rather not use a token at all

The same thing can be done by hand in the Cloudflare dashboard. Open that
server's pool, turn its endpoint's **Enabled** setting off, wait for the drain duration, restart
the server, then turn it back on. The result is identical; it is just manual,
and it has to be done at the right moment every time.

## Rules that matter

**Never take both servers out together.** That leaves both pools empty and the
load balancer with nowhere to send traffic. Nothing will stop you, not the script
and not the dashboard, and because each server reads only its own pool, a server
being taken out cannot tell that the other one is already out. Check the other
server before you start, either by running `openfn-lb-drain status` on it or by
looking at both pools in the dashboard.

**Always put a server back.** One left disabled means the other carries
everything with no redundancy, and nothing outside tells you: the site keeps
working normally. Running `openfn-lb-drain status` on each server will show it,
as will the pool page.

**If something goes wrong mid-update**, put both servers back into their pools.
A server serving an older version is far better than a server Cloudflare refuses
to use.

## Troubleshooting

| What you see | What it means |
|---|---|
| `no /opt/openfn/cf-lb.env` | the file is missing, or not readable by the user running the script |
| `no origin called 'x' in the pool` | `CF_ORIGIN_NAME` does not match the endpoint name in Cloudflare |
| HTTP 403 from Cloudflare | the token lacks **Load Balancing: Monitors and Pools: Edit**, or it was created for the wrong account |
| The drain returns instantly | `CF_DRAIN_SECONDS` is 0 or unset |

To confirm the site itself is fine at any point:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://openfn.example.org/
```

`302` is correct. It is the redirect to the login page.
