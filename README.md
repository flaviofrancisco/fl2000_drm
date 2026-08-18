[![Gitter](https://badges.gitter.im/fl2000_drm/community.svg)](https://gitter.im/fl2000_drm/community?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge)
[![Build](https://github.com/klogg/fl2000_drm/actions/workflows/makefile.yml/badge.svg)](https://github.com/klogg/fl2000_drm/actions/workflows/makefile.yml)
[![Stylecheck](https://github.com/klogg/fl2000_drm/actions/workflows/codingstyle.yaml/badge.svg)](https://github.com/klogg/fl2000_drm/actions/workflows/codingstyle.yaml)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=klogg_fl2000_drm&metric=alert_status)](https://sonarcloud.io/dashboard?id=klogg_fl2000_drm)

# Linux kernel FL2000DX/IT66121FN dongle DRM driver

Clean re-implementation of FrescoLogic FL2000DX DRM driver and ITE Tech IT66121F driver, allowing to enable full display controller capabilities for [USB-to-HDMI dongles](https://www.aliexpress.com/item/32821739801.html?spm=a2g0o.productlist.0.0.14ee52fb8rFfu5) based on such chips in Linux

### Building driver

Check out the code and type
```
make
```
Use
```
insmod fl2000.ko && insmod it66121.ko
```
with sudo or in root shell to start the driver. If you are running on a system with secure boot enabled, you may need to sign kernel modules. Try using provided script for this:
```
./scritps/sign.sh
```
ensure that DRM components are loaded in your system, if not - please use
```
modprobe drm
modprobe drm_kms_helper
```
**NOTE:** proper kernel headers and build tools (e.g. "build-essential" package) must be installed on the system. Driver is developed and tested on Ubuntu 22.04 with **Linux kernel 6.5.0**, so better to test it this way. Please use gcc-8 or newer to build the driver

Also ported and tested on **Ubuntu 26.04 LTS with Linux kernel 7.0.0** — see [Ubuntu 26.04 / kernel 7.0 port](#ubuntu-2604-lts--kernel-70-port) below for what changed and its current limitations.

For more information check project's [Wiki](https://github.com/klogg/fl2000_drm/wiki)

## Ubuntu 26.04 LTS / kernel 7.0 port

The driver was ported forward to build and run against the modern DRM core shipped with Ubuntu 26.04 LTS (kernel 7.0.0). Summary of what changed:

- **Modern `drm_edid` API**: `bridge/it66121_drv.c` was switched from the legacy `struct edid`/`drm_do_get_edid()`/`drm_add_edid_modes()` calls to `struct drm_edid`, `drm_edid_read_custom()`, `drm_edid_connector_update()` and `drm_edid_connector_add_modes()`, matching the current DRM core.
- **fbdev setup**: `fl2000_drm.c` now uses `drm_client_setup_with_fourcc()` / `DRM_FBDEV_DMA_DRIVER_OPS` instead of the removed `drm_fbdev_generic_setup()`; `DRM_DRIVER_DATE` and `FL2000_FB_BPP`, no longer used by the current DRM core, were dropped.
- **Bridge lifetime**: `it66121_probe()`/`it66121_remove()` moved to `devm_drm_bridge_alloc()`, dropping manual `kzalloc`/`kfree` of the private context. `it66121_bridge_attach()` was updated to the current `(bridge, encoder, flags)` signature.
- **DDC/EDID FIFO read fix**: reworked the EDID block-read routine to issue one full `EDID_READ` command cycle per byte instead of draining the IT66121 FIFO in bursts, and to re-assert PC-host DDC master selection before every DDC operation (see [Limitations](#known-limitations-ubuntu-2604--kernel-70) below — this only partially works around the underlying hardware constraint).
- **I2C adapter binding**: the FL2000 virtual I2C adapter is now located by its bus name ("FL2000 bridge I2C bus") instead of a hardcoded/module-param bus number, since the assigned bus number varies across boots and could otherwise collide with an unrelated onboard GPU's IT66121-family chip at the same I2C address.
- **Initial hotplug detection**: connector polling (`DRM_CONNECTOR_POLL_CONNECT|DISCONNECT`) is now enabled and an initial `drm_kms_helper_hotplug_event()` is fired at bind time, since the bridge only signals HPD on a plug/unplug edge and would otherwise miss a monitor that was already connected when the module loads (e.g. on a reload).
- **DMA mask for PRIME imports**: `drm->dev->dma_mask` is now pointed at the device's own coherent mask storage before deriving both masks from the parent USB device, so PRIME dma-buf imports (used by compositors to scan out GPU-rendered frames on this display-only adapter) pass DMA mapping validation.
- **Software cursor plane**: added an alpha-blended `DRM_PLANE_TYPE_CURSOR` plane (`ARGB8888`, up to 64x64) that is composited in software onto a cached copy of the primary framebuffer before being sent over the streaming interface, since there is no hardware cursor and userspace's software-cursor fallback doesn't reliably reach this display-only, renderless USB adapter.
- **Streaming buffer/locking fixes**: fixed several `spin_unlock()` calls that needed to be `spin_unlock_irq()` to match their paired `spin_lock_irq()`; buffers are now removed from their list and the lock dropped *before* the (multi-MB) pixel copy/compression work runs, instead of holding the spinlock (and therefore interrupts) for the whole operation — this was starving USB completion handling and underrunning the device's video FIFO, especially under fast cursor movement. When no free buffer is available, a still-queued (not yet submitted) frame is now overwritten with newer content instead of every stale frame being sent out in sequence, reducing judder under fast-changing content.
- **Misc**: fixed a mode pixel-clock search loop (`fl2000_mode_calc()`) whose sign variable was initialized to `0` instead of `1`, which made `-s` a no-op and silently disabled the htotal adjustment search entirely.

### Known limitations (Ubuntu 26.04 / kernel 7.0)

- **EDID cannot reliably be read from the display over DDC.** The FL2000 bridge's I2C hardware can only fetch 4-byte-aligned words, so a read of the IT66121's `DDC_RD_FIFO` register is actually issued as a read of a 4-byte register block with the FIFO byte extracted as the last byte. The IT66121 only serves a fresh FIFO byte when the I2C transaction starts exactly at the FIFO register address; reaching it via auto-increment does not trigger that. As a result the FIFO can never be reliably drained through this bridge, and the driver falls back to a built-in generic EDID instead of the monitor's real one.
- **Fallback EDID limits available modes/resolution.** The built-in fallback EDID advertises 1280x720@60 as the *preferred* mode (with 1920x1080@60, 1600x900@60, 1280x1024@60 and 1024x768@60 offered as additional selectable timings). 1920x1080 was tried as the preferred mode but reverted: `drm_fbdev_dma_setup()` sizes the initial console framebuffer off the preferred mode, and the resulting ~8MB allocation reliably fails with `-ENOMEM` on tested hardware (fragmented physical memory after boot), leaving the display appearing as if nothing were connected. 1920x1080 can still be selected manually once a session is up. The monitor's actual EDID (real preferred timing, audio capabilities, HDR/color metadata, etc.) is not used.
- **Only one IT66121 bridge instance is supported** — the driver keeps a single global `ctx` pointer (`bridge/it66121_drv.c`); a system with more than one FL2000/IT66121 dongle attached is not supported.
- **No hardware cursor** — the cursor plane added in this port is software-composited (CPU alpha blend on every plane/primary update), not accelerated by the device.
- **Various long-standing `TODO`/`XXX` markers remain unaddressed**, carried over from before this port, including: no I2C/EDID/SPI register access locking in the bridge driver, no mode validation in `it66121_connector_mode_valid()`, no suspend/resume implementation in `fl2000_drv.c`, and no recovery path for `vga_error`/`lbuf_halt` streaming register faults (`fl2000_registers.c`).
- Driver has been ported and smoke-tested on Ubuntu 26.04 LTS with Linux kernel 7.0.0; it has not been through the same breadth of testing as the Ubuntu 22.04 / kernel 6.5.0 baseline, so regressions on that older baseline are possible even though no functional changes were made to the FL2000-only code paths.
