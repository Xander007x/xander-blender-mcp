# Blender 5.0 Subdivision Crash Fix

## Summary

Blender 5.0.1 crashes with `EXCEPTION_ACCESS_VIOLATION` (null-pointer `memcpy`) when objects are created immediately after deleting all objects via MCP scripting. This affects both the GPU and CPU subdivision code paths.

**Affected version:** Blender 5.0.1 (commit `a3db93c5b259`, 2025-12-15)  
**Hardware:** NVIDIA RTX 5090 (32GB GDDR7), driver `32.0.15.9186`  
**CPU:** Intel Core Ultra 9 285K (24C/24T)  
**OS:** Windows 11

---

## Crash Details

### Trigger Sequence

```python
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()
bpy.ops.mcp.start_server()
bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, radius=0.5, ...)
```

The crash occurs when objects are created via scripting (MCP) immediately after clearing/deleting all objects, without allowing the depsgraph to fully flush.

### Crash #1 — GPU Subdivision Path

```
ExceptionCode: EXCEPTION_ACCESS_VIOLATION (0xc0000005)
Parameters: write to address 0x0000000000000000

VCRUNTIME140.dll    memcpy
blender.exe         draw_subdiv_topology_info_cb
blender.exe         foreach_subdiv_geometry
blender.exe         draw_subdiv_build_cache
blender.exe         draw_subdiv_create_requested_buffers
blender.exe         DRW_create_subdivision
blender.exe         DRW_mesh_batch_cache_create_requested
blender.exe         drw_batch_cache_generate_requested
blender.exe         drw_engines_cache_populate
blender.exe         DRWContext::sync
blender.exe         DRW_draw_view
blender.exe         view3d_main_region_draw
```

**Cause:** The viewport draw loop attempts to build GPU subdivision draw caches for the newly created mesh while stale data from deleted objects still occupies internal buffers.

### Crash #2 — CPU Subdivision Path

After disabling GPU subdivision (switching to CPU mode), the crash moved to the CPU subdiv path:

```
ExceptionCode: EXCEPTION_ACCESS_VIOLATION (0xc0000005)
Parameters: write to address 0x0000000000000000

VCRUNTIME140.dll    memcpy
blender.exe         customData_add_layer__internal
blender.exe         customdata_merge_internal
blender.exe         subdiv_mesh_topology_info
blender.exe         foreach_subdiv_geometry
blender.exe         subdiv_to_mesh
blender.exe         mesh_wrapper_ensure_subdivision
blender.exe         BKE_mesh_wrapper_ensure_subdivision
blender.exe         modify_mesh
blender.exe         mesh_calc_modifiers
blender.exe         mesh_data_update
blender.exe         BKE_object_handle_data_update
blender.exe         scene_graph_update_tagged
blender.exe         wm_event_do_refresh_wm_and_depsgraph
```

**Cause:** The deferred depsgraph refresh (`wm_event_do_refresh_wm_and_depsgraph`) runs with stale mesh references in `customData`, passing a null destination pointer to `memcpy` via `customData_add_layer__internal`.

### Root Cause

**The primary crash trigger was the `MCPSERVER_OT_start_server` operator itself.** The operator's `execute()` method called:

```python
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()
```

These raw Blender operators schedule a **deferred** `wm_event_do_refresh_wm_and_depsgraph`. Unlike `bpy.data.objects.remove()` (which immediately purges data), `bpy.ops.object.delete()` defers the depsgraph refresh to the next event loop tick. When the MCP server then receives a mesh creation request, the deferred refresh races with the new object creation and the subdivision code encounters stale/null customdata pointers.

This was exacerbated by:
- A **duplicate class definition** of `MCPSERVER_OT_start_server` (the second silently overwrote the first)
- The **auto-start timer** (`auto_start_mcp.py`) that calls `bpy.ops.mcp.start_server()` 3 seconds after launch, triggering the unsafe delete path automatically

The `clear_scene()` MCP tool was already safe (using `bpy.data.objects.remove()`), but the operator that starts the server was clearing the scene via the raw crash-prone path.

This does **not** occur when using Blender's GUI (Edit → Delete) because the GUI inserts implicit frame delays between operations, allowing the depsgraph to fully flush.

---

## Fixes Applied

### Fix 0: Start Server Operator — THE ACTUAL FIX (`blender_mcp.py`)

The duplicate `MCPSERVER_OT_start_server` class definitions were merged into one, and the unsafe `bpy.ops.object.select_all` + `bpy.ops.object.delete()` were replaced with the safe `bpy.data` API:

```python
# BEFORE (CRASHED):
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete()

# AFTER (SAFE):
for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj, do_unlink=True)
for mesh in list(bpy.data.meshes):
    if mesh.users == 0:
        bpy.data.meshes.remove(mesh)
for mat in list(bpy.data.materials):
    if mat.users == 0:
        bpy.data.materials.remove(mat)
bpy.context.view_layer.update()
depsgraph = bpy.context.evaluated_depsgraph_get()
depsgraph.update()
```

This is the same approach used by the `clear_scene()` tool, which never exhibited the crash.

### Fix 1: Blender Addon (`blender_mcp.py`)

**Commits:** `8206c49`, `1c0edc2`

#### `clear_scene()` — Thorough orphaned data purge + full depsgraph evaluation

```python
# Clean ALL orphaned data blocks (meshes, curves, lights, cameras, etc.)
for attr in ('lights', 'cameras', 'armatures', 'grease_pencils',
             'lattices', 'metaballs', 'particles', 'speakers',
             'volumes', 'fonts'):
    collection = getattr(bpy.data, attr, None)
    if collection is not None:
        for block in list(collection):
            if block.users == 0:
                collection.remove(block)

# Full depsgraph flush — view_layer.update() alone is NOT enough
bpy.context.view_layer.update()
depsgraph = bpy.context.evaluated_depsgraph_get()
depsgraph.update()
```

#### `delete_objects()` — Same thorough depsgraph flush after deletion

```python
if deleted or children_deleted:
    bpy.context.view_layer.update()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    depsgraph.update()
```

#### `create_mesh_object()` — Pre-creation depsgraph flush

```python
# Before creating any new object, flush pending depsgraph work
depsgraph = bpy.context.evaluated_depsgraph_get()
depsgraph.update()
```

#### `boolean_operation()` — Depsgraph update after modifier apply/object delete

```python
bpy.context.view_layer.update()
```

### Fix 2: Orchestrator (`orchestrator/server.js`)

**Commits:** `edd2be3`, `ff007ca`

- Forces CPU render device before executing any Blender tool plan
- Expanded `SCENE_MUTATING_TOOLS` set to include `clear_scene`, `delete_objects`, `boolean_operation`
- Calls `clear_cache` + `get_scene_info` after every scene-mutating operation
- Added 500ms delay between operations to allow Blender's deferred depsgraph refresh to complete

### Fix 3: Blender Startup Script

**File:** `%APPDATA%\Blender Foundation\Blender\5.0\scripts\startup\mcp_cpu_safe_prefs.py`

Auto-configures CPU-safe defaults on every Blender launch:

| Setting | Value | API Property |
|---------|-------|-------------|
| GPU Subdivision | Off | `system.use_gpu_subdivision = False` |
| Render Device | CPU | `cycles.device = "CPU"` |
| Denoiser | OpenImageDenoise | `cycles.denoiser = "OPENIMAGEDENOISE"` |
| Compositor | CPU | `system.use_gpu_compositor = False` |
| Sequencer | CPU | `system.use_gpu_sequencer = False` |
| Texture Painting | CPU | `system.use_gpu_texture_painting = False` |

**Note:** The `blender_render` tool in the orchestrator overrides to `device: "GPU"` for final Cycles renders, which is safe because rendering uses a separate pipeline from the viewport draw loop.

---

## Key Learnings

1. **`bpy.context.view_layer.update()` is not sufficient** — it triggers a view layer update but does not force a full depsgraph evaluation. Stale data can persist in the deferred refresh queue.

2. **`bpy.context.evaluated_depsgraph_get()` + `depsgraph.update()`** forces a complete evaluation, flushing all pending notifiers and ensuring no stale references remain.

3. **The crash is not GPU-specific** — disabling GPU subdivision moves the crash to the CPU subdivision path. The root cause is stale depsgraph data, not a GPU driver bug.

4. **The crash only occurs via scripting** — Blender's GUI naturally inserts frame delays between user actions, giving the depsgraph time to refresh. MCP/scripting fires operations back-to-back without these implicit delays.

5. **Orphaned data blocks must be proactively purged** — `bpy.data.objects.remove()` leaves orphaned mesh/curve/etc. data blocks. These must be explicitly removed before the depsgraph flush to prevent stale references.

---

## Potential Blender Bug Report

This appears to be a bug in Blender 5.0's depsgraph/subdivision code. A bug report could be filed at [projects.blender.org](https://projects.blender.org/) with:

- **Component:** Dependency Graph / Subdivision Surface
- **Severity:** Crash
- **Minimal repro:**
  ```python
  import bpy
  # Start with default scene (cube exists)
  bpy.ops.object.select_all(action='SELECT')
  bpy.ops.object.delete()
  bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, radius=0.5)
  # Crash occurs in next viewport refresh
  ```
- **Expected:** Object creation after deletion should work without crashes
- **Actual:** `EXCEPTION_ACCESS_VIOLATION` in `customData_add_layer__internal` or `draw_subdiv_topology_info_cb`
- **Workaround:** Call `bpy.context.evaluated_depsgraph_get().update()` between delete and create operations

---

## File References

| File | Repository | Description |
|------|-----------|-------------|
| `addon/blender_mcp.py` | xander-blender-mcp | Blender addon with depsgraph fixes |
| `orchestrator/server.js` | llm-cluster | Orchestrator with safety delays |
| `blender.crash.txt` | llm-cluster | Original crash logs (both GPU + CPU paths) |
| `mcp_cpu_safe_prefs.py` | Blender user scripts | Startup preferences script |
