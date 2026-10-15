// The `require` an extension bundle sees. Bundles leave the host modules and selected store
// dependencies external; those dependencies are bundled into Oz's runtime instead.

import { nodeModules } from "./node-shims.js";
import Color from "colorjs.io";
import colorNamer from "color-namer";
import uniqBy from "lodash/uniqBy.js";
import { environment, launchCommand } from "./api/system.js";

const registry = new Map();

export function defineModule(name, exports) {
  registry.set(name, exports);
}

for (const name of Object.keys(nodeModules)) defineModule(name, nodeModules[name]);

defineModule("colorjs.io", Color);
defineModule("color-namer", colorNamer);
defineModule("lodash/uniqBy", uniqBy);
defineModule("raycast-cross-extension", {
  callbackLaunchCommand(options, result) {
    return launchCommand({
      ...options,
      context: { ...options.context, ...result },
    });
  },
  crossLaunchCommand(options, callbackLaunchOptions) {
    if (callbackLaunchOptions === false) return launchCommand(options);
    return launchCommand({
      ...options,
      context: {
        ...options.context,
        callbackLaunchOptions: {
          name: environment.commandName,
          extensionName: environment.extensionName,
          ownerOrAuthorName: environment.ownerOrAuthorName,
          type: "userInitiated",
          ...callbackLaunchOptions,
        },
      },
    });
  },
});

export function requireModule(name) {
  const key = String(name);
  if (registry.has(key)) return registry.get(key);
  // Deep imports into a provided package (`react-dom/client`) resolve to the package itself rather
  // than exploding, which is enough for the handful of bundles that reference them defensively.
  const root = key.startsWith("@") ? key.split("/").slice(0, 2).join("/") : key.split("/")[0];
  if (registry.has(root)) return registry.get(root);
  throw new Error(
    `Cannot find module '${key}'. Oz provides React, @raycast/api and a subset of Node builtins — see docs/extensions.md.`,
  );
}

/// Evaluate one CJS bundle. `filename`/`dirname` matter: extensions resolve bundled assets relative
/// to `__dirname`, and `environment.assetsPath` points at the same directory.
export function evaluateCommonJS(code, filename, dirname) {
  const module = { exports: {}, id: filename, filename, loaded: false, children: [], paths: [] };
  const factory = globalThis.__ozCompile(code, filename);
  factory(module.exports, requireModule, module, filename, dirname);
  module.loaded = true;
  return module.exports;
}
