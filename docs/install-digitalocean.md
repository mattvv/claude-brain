# Installing on a DigitalOcean droplet

A rented cloud VM: about $12/month, always on by definition, nothing of yours to
keep awake. Use this if you don't have a computer that stays on — otherwise
[install on your own machine](install-local.md), which is free.

## The scripted path

```bash
curl -fsSL https://raw.githubusercontent.com/mattvv/claude-brain/main/install.sh | bash
```

Choose **a new cloud server**. It installs DigitalOcean's `doctl`, asks you to
paste an API token (from <https://cloud.digitalocean.com/account/api/tokens>,
Read **and** Write), creates the droplet, waits for it to install itself, and
hands you off to `brain setup` over SSH.

Flags, if you want to skip the questions:

```bash
bash install.sh --digitalocean --name claude-brain --region sfo3 --size s-1vcpu-2gb
```

Costs: billed hourly. Powering the droplet off in the DO console still bills for
the disk — to stop paying, **destroy** it (`doctl compute droplet delete
claude-brain`), which also erases every login on it.

## The click-through path (no terminal)

Use this if you'd rather click through the DigitalOcean website. You still need a
terminal for one step at the end (connecting to the droplet), but nothing has to
be installed on your laptop.

## 1. Get the bootstrap file

Open the raw file
[`cloud-init.yaml`](https://raw.githubusercontent.com/mattvv/claude-brain/main/cloud-init.yaml)
in your browser and copy its entire contents.

## 2. Create the droplet

1. In the [DigitalOcean console](https://cloud.digitalocean.com), click
   **Create → Droplets**.
2. **Region**: pick one near you.
3. **Image**: Ubuntu **24.04 (LTS) x64**.
4. **Size**: Basic → Regular → **2 GB / 1 CPU** ($12/mo). Smaller sizes will fail the build.
5. **Authentication**: choose **SSH Key** and add your key
   (DigitalOcean shows how to create one if you don't have one — don't use a password).
6. Open **Advanced Options** and tick **Add Initialization scripts (free)** —
   paste the `cloud-init.yaml` contents into the **User data** box.
7. Set the hostname to `claude-brain` and click **Create Droplet**.

## 3. Wait, then connect

Give it **5–10 minutes** after it shows as active — it's installing everything in the
background. Then, in a terminal:

```bash
ssh brain@YOUR_DROPLET_IP
```

(The IP is shown in the DO console. The user is `brain`, not `root`.)

You'll see a welcome hint. Run:

```bash
brain setup
```

and follow the wizard. From here on it is identical to every other install.

## Optional: make `ssh claude-brain` work

Add this to `~/.ssh/config` on your laptop (create the file if needed):

```
Host claude-brain
  HostName YOUR_DROPLET_IP
  User brain
```
