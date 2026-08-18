# Manual setup (no terminal on your laptop)

Use this path if you'd rather click through the DigitalOcean website than run
`setup.sh`. You still need a terminal for one step at the end (connecting to the
droplet), but nothing has to be installed on your laptop.

## 1. Get the bootstrap file

Open the raw file
[`cloud-init.yaml`](https://raw.githubusercontent.com/REPO_OWNER/claude-brain/main/cloud-init.yaml)
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

and follow the wizard — it's the same experience as the scripted path from Step 3 of the
[README](../README.md) onward.

## Optional: make `ssh claude-brain` work

Add this to `~/.ssh/config` on your laptop (create the file if needed):

```
Host claude-brain
  HostName YOUR_DROPLET_IP
  User brain
```
