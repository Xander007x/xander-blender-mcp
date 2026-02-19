"""
polymcp_toolkit shim — Provides the `expose_tools` function without requiring
the full PolyMCP package.  This is a lightweight replacement that creates a
FastAPI application with MCP-compatible endpoints from a list of Python functions.

The poly-mcp Blender addon (blender_mcp.py) imports:
    from polymcp_toolkit import expose_tools

By placing this module in Blender's site-packages (or on sys.path), we satisfy
that import without needing the full polymcp package installed.
"""

import inspect
import json
import logging
from typing import Any, Callable, Dict, List, Optional

logger = logging.getLogger(__name__)

try:
    from fastapi import FastAPI, HTTPException
    from pydantic import BaseModel
except ImportError:
    raise ImportError(
        "polymcp_toolkit shim requires fastapi and pydantic. "
        "Install them with: pip install fastapi pydantic"
    )


class ToolInvocationRequest(BaseModel):
    """Request body for tool invocation — accepts arbitrary kwargs."""
    class Config:
        extra = "allow"


def _extract_param_info(func: Callable) -> Dict[str, Any]:
    """Extract parameter information from a function signature."""
    sig = inspect.signature(func)
    params = {}
    for name, param in sig.parameters.items():
        info = {
            "required": param.default is inspect.Parameter.empty,
        }
        if param.annotation is not inspect.Parameter.empty:
            try:
                info["type"] = getattr(param.annotation, "__name__", str(param.annotation))
            except Exception:
                info["type"] = str(param.annotation)
        if param.default is not inspect.Parameter.empty:
            try:
                json.dumps(param.default)  # Check if JSON serializable
                info["default"] = param.default
            except (TypeError, ValueError):
                info["default"] = str(param.default)
        params[name] = info
    return params


def _extract_docstring(func: Callable) -> str:
    """Extract and clean docstring from a function."""
    doc = inspect.getdoc(func)
    if not doc:
        return ""
    # Return just the first paragraph (description)
    paragraphs = doc.split("\n\n")
    return paragraphs[0].strip()


def expose_tools(
    tools: List[Callable],
    title: str = "MCP Server",
    description: str = "",
    version: str = "1.0.0",
) -> FastAPI:
    """
    Create a FastAPI application that exposes Python functions as MCP tools.

    This is a drop-in replacement for polymcp_toolkit.expose_tools that creates
    the same REST API endpoints:
        GET  /health           — Server health check
        GET  /mcp/list_tools   — List all available tools with parameters
        POST /mcp/invoke/{name} — Invoke a tool by name with JSON parameters

    Args:
        tools: List of callable functions to expose as MCP tools
        title: Server title for FastAPI docs
        description: Server description
        version: API version string

    Returns:
        Configured FastAPI application
    """
    app = FastAPI(title=title, description=description, version=version)

    # Build tool registry
    tool_map: Dict[str, Callable] = {}
    tool_info: List[Dict[str, Any]] = []

    for func in tools:
        name = func.__name__
        tool_map[name] = func
        tool_info.append({
            "name": name,
            "description": _extract_docstring(func),
            "parameters": _extract_param_info(func),
        })

    logger.info(f"[polymcp_toolkit] Registered {len(tool_map)} tools")

    # ── Endpoints ────────────────────────────────────────────────────

    @app.get("/health")
    async def health():
        return {
            "status": "ok",
            "server": title,
            "version": version,
            "tools": len(tool_map),
        }

    @app.get("/mcp/list_tools")
    async def list_tools():
        return {
            "tools": tool_info,
            "count": len(tool_info),
        }

    @app.post("/mcp/invoke/{tool_name}")
    async def invoke_tool(tool_name: str, body: Optional[Dict[str, Any]] = None):
        if tool_name not in tool_map:
            raise HTTPException(
                status_code=404,
                detail=f"Tool '{tool_name}' not found. Use GET /mcp/list_tools to see available tools.",
            )

        func = tool_map[tool_name]
        params = body or {}

        try:
            result = func(**params)
            return {"success": True, "tool": tool_name, "result": result}
        except TypeError as e:
            # Parameter mismatch — give a helpful error
            sig = inspect.signature(func)
            expected = list(sig.parameters.keys())
            raise HTTPException(
                status_code=422,
                detail={
                    "error": str(e),
                    "tool": tool_name,
                    "expected_parameters": expected,
                    "received_parameters": list(params.keys()),
                },
            )
        except Exception as e:
            logger.error(f"[polymcp_toolkit] Error invoking {tool_name}: {e}")
            return {
                "success": False,
                "tool": tool_name,
                "error": str(e),
                "error_type": type(e).__name__,
            }

    return app
