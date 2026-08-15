import assert from "node:assert/strict"
import test from "node:test"

import NavigationDialog from "./navigation_dialog.mjs"

test("moving to desktop closes the dialog and focuses visible main content", () => {
  const listeners = new Map()
  const mediaListeners = new Map()
  const focusLog = []

  const opener = {
    isConnected: true,
    setAttribute(name, value) {
      this[name] = value
    },
    focus() {
      focusLog.push("opener")
    },
  }

  const main = {
    isConnected: true,
    focus() {
      focusLog.push("main")
    },
  }

  const dialog = {
    id: "mobile-navigation-dialog",
    open: true,
    close() {
      this.open = false
      listeners.get("close")({target: this})
    },
  }

  globalThis.document = {
    documentElement: {classList: {remove() {}}},
    getElementById(id) {
      if (id === dialog.id) return dialog
      if (id === "main-content") return main
      return null
    },
    addEventListener(name, listener) {
      listeners.set(name, listener)
    },
    removeEventListener() {},
  }

  globalThis.window = {
    matchMedia() {
      return {
        addEventListener(name, listener) {
          mediaListeners.set(name, listener)
        },
        removeEventListener() {},
      }
    },
  }

  const hook = {el: {dataset: {dialogId: dialog.id}}}
  NavigationDialog.mounted.call(hook)
  hook.returnFocusTo = opener

  mediaListeners.get("change")({matches: true})

  assert.equal(dialog.open, false)
  assert.equal(opener["aria-expanded"], "false")
  assert.deepEqual(focusLog, ["main"])
})
