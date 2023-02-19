# Building and running the game

Install the required dependencies, example for Fedora:

```sh
sudo dnf install SDL2-devel SDL2_image-devel
```

Install zig 0.11.0 and run `zig build run` inside the projects directory.

## Controls

* **arrow keys** - Move
* **space + arrow keys** - Strafe
* **right ctrl + arrow keys** - Rotate slowly
* **t** - Toggle top-down view
* **F2** - Save map to disk
* **F5** - Reload map from disk
* **left mouse button** - Start/stop placing object
* **mouse wheel** - Zoom in/out
* **right mouse button + mouse wheel** - Cycle trough placeable objects _(see console output)_
* **middle mouse button** - Cycle trough object types _(see console output)_
* **delete** - Toggle delete/insert mode
