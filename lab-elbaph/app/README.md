# ELBaph lab — web app

Small Go application used by the ELBaph Terraform demo: a deliberately unsafe “dig” form, diagnostics page, and ops-mode dashboard.

## Requirements

- Go 1.22 or newer
- `dig` available in your `PATH`

On macOS you can usually install `dig` with:

```bash
brew install bind
```

## Run locally

From this folder:

```bash
go run .
```

The app listens on `http://127.0.0.1:8080`.

Optional environment variables:

```bash
PORT=8080
APP_MODE=web
OPS_LINK_URL=http://<ops-alb-url>/   # e.g. terraform output -raw ops_alb_url
```

Useful local flow:

1. Open `http://127.0.0.1:8080/`
2. Submit `example.com`
3. Try a command-injection style payload such as `example.com; id`
4. Visit `http://127.0.0.1:8080/diagnostics`
5. Visit `http://127.0.0.1:8080/errors/geo-blocked.html`

`APP_MODE=ops` switches the app into the internal operations dashboard mode used on the ops EC2 instance.
