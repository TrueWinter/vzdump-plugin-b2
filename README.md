# Encrypted off-site backup of Proxmox VE vzdump images for $5/month/TB

This plugin to `vzdump` will hook into after a single VM backup is done.
It will 
- split the `.vma.lzo` file that `vzdump` wrote to chunks of configurable size (default is 2 GB, B2 allows up to 5 GB=5*10^9 byte)
- encrypt them using a symmetric key (password - no GPG keys used),
- upload them to Backblaze B2 to a configurable path (default: hostname) under a configurable bucket,
- delete the local copy of the backup and
- remove all remote backups at B2 for the VM/LXC except the one it just uploaded.

Every step is checksummed and the checksum file is uploaded as well.

After all chunk uploads are finished, **the local copy of the backup is deleted**.
Therefore you only need twice the size of the largest VM's backup file
on the host. The backup is read and written multiple times, so using different
storage devices for VMs and backup is a good idea.

## Preparation

- Get a Backblaze account and generate an application key along with a bucket.
- Install git and download this repository:

  ```
  apt-get install -y git
  git clone https://github.com/TrueWinter/vzdump-plugin-b2.git /usr/local/bin/vzdump-plugin-b2
  ```

  Alternatively transfer it manually to the server.
- Install jq:

  ```
  apt-get install -y jq
  ```

- Make a copy of `upload-b2.config.template` and edit it to your parameters.
  If you put it anywhere else than the filename `upload-b2.config` in the
  same directory as `vzdump-plugin-upload-b2.sh`, also edit that script and
  make `CONFIG_FILE` point to it.
- In that config file, note GPG_PASSPHRASE_FILE. That should point to a
  file containing your long, random and secret passphrase. You can use this
  do generate one:

  ```
  test -r /root/vzdump-passphrase.txt || dd if=/dev/random bs=1 count=48 2>/dev/null | hexdump -v -e '"%02X"' > /root/vzdump-passphrase.txt
  ```

   **Remember and save that string** - your backups are unusable without it!
- Make `vzdump` aware of the script by adding a line to `/etc/vzdump.conf`:

  ```
  echo "script: /usr/local/bin/vzdump-plugin-b2/vzdump-plugin-upload-b2.sh" >> /etc/vzdump.conf
  ```

- Download the `b2` command-line utility as documented [here](https://www.backblaze.com/b2/docs/quick_command_line.html):

  ```
  wget -O /usr/local/bin/b2 https://github.com/Backblaze/B2_Command_Line_Tool/releases/latest/download/b2-linux
  chmod +x /usr/local/bin/b2
  ```
  
Note that container backups are only a few hundred MB, while VM backups are at least 2.5GB (at least for Ubuntu). For this reason, it is recommended that you use containers wherever possible.

## Testing

A manual backup of a small VM is a good idea to test general functionality. Look at the log output for hints what may have gone wrong.

## Restoring backups

To restore backups, run the `vzdump-b2-verify.sh` script. You will need to pass three parameters:

- The directory inside the bucket, e.g. `hostname/rpool/backup/dump`
- The name of the (compressed) backup file, e.g. 'vzdump-qemu-100-2016_02_11-12_15_02'
- A directory where the script can work. This directory must be empty

This script will download the files from Backblaze B2, decrypt them, verify the checksums, and join the split files together.