# india-vm

Scripts to spin up a disposable Windows Server 2022 VM in AWS Mumbai (`ap-south-1`) on demand, RDP into it, and tear it down when done. The VM is a **spot instance**, so you only pay while it runs. An S3 bucket is mounted on it as drive `Z:` so your files outlive the VM.

## What you get

- Windows Server 2022 on a spot `t3.medium`, RDP open only to your current IP
- Software from the `SOFTWARE` list in `config.sh` (plus Chrome) installed at first boot via Chocolatey
- Your S3 bucket mounted as `Z:` at every logon (rclone + WinFsp, using the instance's IAM role)
- Optional daily email reminder if the VM is still running, with a one-click terminate link

Anything on the VM's `C:` drive is **lost on termination**. Keep files on `Z:`.

## Scripts

| File | What it does |
|---|---|
| `config.sh` | Settings: instance type, region, software list, S3 bucket name, resource names. Looks up the latest Windows Server 2022 AMI. Sourced by the other scripts, not run directly. |
| `launch.sh` | Creates anything missing (IAM user, key pair, security group, instance role, S3 bucket), then launches the spot VM and prints the IP. Safe to rerun; it skips what exists and exits if the VM is already running. |
| `terminate.sh` | Terminates the running `india-windows` instance. Stops compute charges. |
| `setup-alert.sh` | One-time setup of the reminder: a daily Lambda emails you if the VM is running (uptime, estimated cost, terminate link). Also creates the terminate Lambda behind an API Gateway URL guarded by a secret token. |

## Prerequisites

- AWS CLI v2, `python3`, `zip`, `curl`
- An AWS account and an **admin-level** profile. `launch.sh` creates IAM users and roles, so a restricted user won't work.

## Setup and run

1. **Log in to AWS** with the `aws-india` profile (admin-level, region `ap-south-1`):
   ```
   aws login --profile aws-india
   export AWS_PROFILE=aws-india
   aws sts get-caller-identity     # confirm it works
   ```
   Sessions expire; if you see "session has expired", run `aws login` again. The `AWS_PROFILE` line in `config.sh` is not exported, so set it in your shell as above.

2. **Edit `config.sh`**: set `S3_BUCKET` to a globally unique name and adjust `SOFTWARE` (Chocolatey package names).

3. **Launch:**
   ```
   ./launch.sh
   ```
   Wait about 5 to 10 minutes after it reports ready for the software installs to finish.

4. **Get the Administrator password** (about 4 minutes after launch):
   ```
   aws ec2 get-password-data --instance-id <instance-id> \
     --priv-launch-key ~/.ssh/india-vm-key.pem \
     --region ap-south-1 --query PasswordData --output text
   ```
   Or in the console: EC2, Instances, Connect, RDP client, Get password, and upload `~/.ssh/india-vm-key.pem`.

5. **RDP** to the printed IP as `Administrator`. `Z:` appears at logon; if you logged in before the boot script finished, sign out and back in.

6. **Terminate when done:**
   ```
   ./terminate.sh
   ```

7. **(Optional) Reminder emails:**
   ```
   ./setup-alert.sh
   ```
   Confirm the AWS subscription email sent to the address in the script, or alerts won't arrive. The email contains a terminate link that anyone holding it can use, so don't forward it.

## Notes

- **IP changes:** the security group allows RDP only from the IP seen when it was created. If your IP changes, add the new one to the `india-vm-rdp` group, or delete the group and rerun `launch.sh`.
- **Keeping installed software:** boot-time installs repeat on every new VM. To keep a hand-configured machine, create an AMI (`aws ec2 create-image`, roughly $1 to $2 a month) and point `AMI_ID` in `config.sh` at it.
- **Boot script runs once:** user-data runs only on a new instance's first boot, so script changes need a terminate and relaunch to take effect.
- **Chrome** installs with `--ignore-checksums` because its Chocolatey package pins a stale checksum.
- **Files created locally:** the private key `~/.ssh/india-vm-key.pem` and the AWS profile `india-vm`. Neither is in the repo.
