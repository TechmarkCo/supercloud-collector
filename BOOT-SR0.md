# Collector VM stopped at `/dev/sr0: Can't open blockdev`

Empty VirtualBox CD-ROM. See SuperCloud `collector/appliance/BOOT-SR0.md`.

On the Mac running VirtualBox:

```bash
chmod +x make-seed-iso.sh
./make-seed-iso.sh SITEID TOKEN
```

Attach `cidata.iso` as the DVD, bridged NIC, hard disk first in boot order.
After login, eject the CD and confirm the site is live on
https://supercloud.techmarkcompany.com/collectors
