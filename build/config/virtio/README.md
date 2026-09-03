# VirtIO drivers (required for this build)

This directory contains the extracted **VirtIO** drivers used by the build.
Windows Setup loads only `viostor` from the generated floppy so it can see the
`virtio` disk. The build uses an in-box `e1000` network adapter for bootstrap.

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

3. The answer file (`Autounattend.xml`) references the boot-critical driver via
   `DriverPaths` -> `A:\viostor`.

CI replaces `viostor` with the pinned driver version and stages the matching
`virtio-win-gt-x64.msi`. Packer installs that MSI in the guest so the finished
image supports VirtIO storage, networking, ballooning, and other devices.

Note: binary driver files placed here are only used during the build and are
not copied into the final image (the `file` provisioner copies `build/config`
to a temp folder that is purged during Sysprep).
