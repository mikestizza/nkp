# Harbor Registry Setup Tool

This script sets up a private Harbor registry for NKP deployments.

## What This Script Does

This script helps you:
- Set up a Harbor registry with all the projects you need
- Push container images needed for NKP
- Fix image references to work with Harbor
- Handle any missing images

## Before You Start

You need:
- A running Harbor registry
- Docker installed
- NKP image bundles downloaded
- Admin access to run Docker commands

## Quick Start

Run the script with default settings:
```bash
./harbor-setup.sh --push-bundles
```

This will:
1. Configure Docker to use your Harbor registry
2. Create all required projects
3. Push core system images
4. Push all NKP bundles to Harbor

## Common Commands

Push everything:
```bash
./harbor-setup.sh --bundle-dir /path/to/bundles --registry-url http://your-harbor-server
```

Push only the image bundles:
```bash
./harbor-setup.sh --skip-docker-config --skip-projects --push-bundles
```

Check registry contents:
```bash
./harbor-setup.sh --skip-docker-config --skip-projects --verify
```

## Fixing Missing Images

If you get errors about missing images during deployment:

1. Use the helper script created at `/tmp/pull-missing-images.sh`
2. Run it with the names of missing images:
```bash
/tmp/pull-missing-images.sh library/pause:3.10 mesosphere/dex:v2.41.1
```

## Important Settings

- Default Harbor URL: `http://10.0.0.114`
- Default username: `admin`
- Default password: `Harbor12345`

Change these settings using command options:
```bash
./harbor-setup.sh --registry-url http://your-harbor --username youruser --password yourpass
```

## Need Help?

Run:
```bash
./harbor-setup.sh --help
```
