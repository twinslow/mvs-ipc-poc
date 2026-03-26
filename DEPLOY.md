# STCPOC Automated Deploy

`deploy.sh` automates the edit-build-test cycle for STCPOC running on
MVS 3.8J under Hercules.  It replaces the manual workflow of uploading
source to TSO, submitting build JCL, and issuing console commands with
a single shell command.

---

## What It Does

1. **Generates a single JCL job** (`_deploy.jcl`) that:
   - Uses IEBUPDTE to load all local `.asm` files into
     `STCPOC.SRCLIB` (STCMAIN, STCCLNT, STCREQ, STCDSECT, STCRQPB)
     and `STCPOC.MACLIB` (STCDSECT, STCRQPB) as inline card data
   - Assembles STCMAIN, STCCLNT, and STCREQ (IFOX00)
   - Link-edits STCMAIN into its own module, and STCCLNT+STCREQ
     into a single combined module (IEWL, SETCODE AC=1)
2. **Stops the running STC** via the Hercules HTTP console (`P STCPOC`)
3. **Submits the job** by attaching the JCL to the Hercules card reader
   (`devinit` with `ascii eof` options)
4. **Restarts the STC** (`S STCPOC`)
5. Optionally **generates and submits the test job** (`_test.jcl`,
   derived from `STCTEST.JCL` with `MVS_USERID`/`MVS_PASSWORD`
   injected into the JOB card)

No TSO session or manual file transfer is required.

---

## Prerequisites

- All one-time setup from the main [README.md](README.md) must be
  complete (dataset allocation, APF authorization, PROC installation).
- The Hercules HTTP console must be enabled (see Configuration below).
- `bash` and `curl` must be available (Git Bash, WSL, Cygwin, etc.).

---

## Usage

```
./deploy.sh [OPTIONS]
```

| Command                  | Effect                                      |
|--------------------------|---------------------------------------------|
| `./deploy.sh`           | Stop STC → upload + build → start STC       |
| `./deploy.sh --test`    | Same as above, then submit STCTEST.JCL      |
| `./deploy.sh --build-only` | Upload + build only; leave the STC alone |
| `./deploy.sh --jcl-only`| Generate `_deploy.jcl` without submitting    |
| `./deploy.sh -h`        | Show help with all options and defaults      |

### Typical development cycle

```
# Edit source locally
vim STCMAIN.asm

# Deploy, restart, and test in one shot
./deploy.sh --test

# Check results in SYSLOG / JES2 output
```

---

## Configuration

All settings can be overridden with environment variables.  Defaults
are shown in brackets.

| Variable        | Purpose                                | Default                    |
|-----------------|----------------------------------------|----------------------------|
| `HERC_URL`      | Hercules HTTP console URL              | `http://localhost:8038`    |
| `CARD_DEV`      | Card reader device address             | `00c`                      |
| `STC_NAME`      | Started task name                      | `STCPOC`                   |
| `BUILD_WAIT`    | Seconds to wait for the build job      | `5`                        |
| `HERC_JCL_PATH` | JCL path as seen by Hercules (see below) | same as local path       |
| `MVS_USERID`    | MVS userid for JOB card                | (must be set)              |
| `MVS_PASSWORD`  | MVS password for JOB card              | (must be set)              |

### Enabling the Hercules HTTP console

Add the following to your Hercules configuration file if not already
present:

```
HTTP PORT 8038
```

TK4- has this enabled by default on port 8038.  SDL Hercules Hyperion
typically uses port 8081.  Adjust `HERC_URL` accordingly:

```
export HERC_URL="http://localhost:8081"
```

### Cross-environment paths (WSL + native Windows Hercules)

If you run `deploy.sh` inside WSL but Hercules runs as a native
Windows process, the generated `_deploy.jcl` file is written to the
project directory but Hercules needs a Windows-style path to read it.

Set `HERC_JCL_PATH` to the Windows equivalent:

```
export HERC_JCL_PATH="C:/Users/tony_/dev/mvs-ipc-poc/_deploy.jcl"
```

If both bash and Hercules run in the same environment (both WSL or
both native), no override is needed.

### Persisting overrides

To avoid exporting variables every time, create an `.env` file and
source it before running:

```bash
# deploy.env
export HERC_URL="http://localhost:8081"
export BUILD_WAIT=20
export HERC_JCL_PATH="C:/Users/tony_/dev/mvs-ipc-poc/_deploy.jcl"
```

```
source deploy.env && ./deploy.sh --test
```

---

## How It Works

### Source upload without TSO

The script reads the local `.asm` files and embeds them as inline data
inside IEBUPDTE control statements.  IEBUPDTE's `PARM=NEW` mode with
`./ ADD NAME=member` cards writes (or replaces) named members in an
existing PDS.  Two IEBUPDTE steps run:

- **UPDSRC** — loads STCMAIN, STCCLNT, STCREQ, STCDSECT, STCRQPB
  into `STCPOC.SRCLIB`
- **UPDMAC** — loads STCDSECT and STCRQPB into `STCPOC.MACLIB`

### Card reader submission

The generated JCL is submitted by telling Hercules to attach the file
to the emulated 3505 card reader:

```
devinit <dev> /path/to/_deploy.jcl ascii eof
```

The `ascii` option tells Hercules to translate ASCII to EBCDIC and pad
lines to 80-byte card images.  The `eof` option signals end-of-file
after the last card so JES2 begins processing immediately.

When running in Git Bash / MSYS2, the script auto-converts the JCL
file path to Windows format using `cygpath -m`, and uses
`MSYS_NO_PATHCONV=1` on the `curl` call to prevent Git Bash from
mangling the `/` prefix on MVS operator commands.

### Console commands

MVS operator commands (`P STCPOC`, `S STCPOC`) are sent through the
Hercules HTTP interface.  The script POSTs to the CGI endpoint
(`/cgi-bin/tasks/syslog`) with a `/` prefix that Hercules routes to
the guest OS as an operator command.

### Test job submission

When `--test` is used, the script generates `_test.jcl` by replacing
the JOB card from `STCTEST.JCL` with one that includes `MVS_USERID`
and `MVS_PASSWORD` from your environment, then submits it via the
card reader after the build completes and the STC restarts.

---

## Output Files

| File           | Description                                    |
|----------------|------------------------------------------------|
| `_deploy.jcl`  | Generated build JCL (recreated on each run).   |
| `_test.jcl`   | Generated test JCL (only with `--test`).       |

Both are in `.gitignore` and safe to delete.

---

## Troubleshooting

### "Could not send to Hercules"

- Verify `HERC_URL` points to the correct host and port.
- Confirm the HTTP console is enabled in the Hercules config.
- Check that Hercules is running and the port is not blocked.
- Fallback: run the `devinit` command manually on the Hercules console
  (the script prints the exact command on failure).

### Build job does not appear in JES2

- Check that `CARD_DEV` matches your Hercules card reader address
  (look for `000C  3505` or similar in `devlist` output).
- Verify `HERC_JCL_PATH` is a path Hercules can access.
- Use `--jcl-only` to generate the JCL, then manually attach it to
  confirm the card reader setup works.

### Assembly errors after deploy

- Run `--jcl-only` and inspect `_deploy.jcl` to verify the inline
  source looks correct (no truncation, no stray characters).
- Check JES2 output for SYSPRINT from the ASMSTC/ASMCLNT/ASMREQ steps.

### STC does not start after deploy

- The build job may still be running.  Increase `BUILD_WAIT`:
  `BUILD_WAIT=30 ./deploy.sh`
- Check JES2 output to confirm all build steps completed RC=0
  (UPDSRC, UPDMAC, ASMSTC, LNKSTC, ASMCLNT, ASMREQ, LNKCLNT).
- Verify the PROC is still in `SYS2.PROCLIB(STCPOC)`.
