# Manual DNS setup (no API token needed)

In the Cloudflare dashboard for **kosecki.dev**, DNS → Records, add two A records
(proxied OFF — gray cloud, because Let's Encrypt HTTP-01 needs to reach the VM
directly on :80):

| Type | Name | Content          | Proxy | TTL  |
| ---- | ---- | ---------------- | ----- | ---- |
| A    | @    | (your static IP) | DNS only (gray) | Auto |
| A    | *    | (your static IP) | DNS only (gray) | Auto |

That's it. Wait ~30s for the wildcard to spread and test:

```
curl -I https://kosecki.dev/
curl -I https://q4.kosecki.dev/
```

If the wildcard A record isn't supported on your Cloudflare plan (Free supports
it; some plans don't), drop the second row and add explicit A records per
hostname you actually use (`tetris`, `chat`, `quake`, `q2`, `q3`, `q4`,
`quake-mp`, `model`, plus any `<service>.kosecki.dev` you may add later). The
`*.kosecki.dev` wildcard subsumes them.

Verification from anywhere:

```
dig +short @1.1.1.1 kosecki.dev A
dig +short @1.1.1.1 q4.kosecki.dev A
```

Both should return the VM's static IP.

If you ever want the Cloudflare proxy back on (orange cloud) you'd need to
issue an Origin Certificate and serve it from Caddy — see README §"Cloudflare
proxy mode".
