# VirtIO drivers (required for this build)

This directory must contain the extracted **VirtIO** drivers so that Windows
Server Setup can see the `virtio` disk and network device configured in
`windows-server.pkr.hcl` (`disk_interface = "virtio"`, `net_device = "virtio-net"`).

Without these, Windows Setup will not detect the virtual disk and the build fails.

## How to populate

1. Download the stable VirtIO driver ISO for Windows from the Fedora project:
   https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/
   (file: `virtio-win.iso`).
2. Extract its contents into this folder, e.g.:

   ```
   build/config/virtio/
     vioscsi/      (storage controller)
     viostor/      (storage controller)
     NetKVM/       (network adapter)
     viorng/       (optional)
     ...
   ```

3. The answer file (`Autounattend.xml`) references these drivers via
   `DriverPaths` -> `A:\virtio`. If your build CD mounts the answer file on a
   different drive letter, update that path in `Autounattend.xml`.

Note: binary driver files placed here are only used during the build and are
not copied into the final image (the `file` provisioner copies `build/config`
to a temp folder that is purged during Sysprep).
