import assert from "node:assert/strict"
import test from "node:test"

import {closeDropdownsOutside} from "./dismissible_dropdowns.mjs"

test("closes open dropdowns that do not contain the interaction target", () => {
  const insideTarget = {}
  const outsideTarget = {}
  const containingDropdown = {
    open: true,
    contains(target) {
      return target === insideTarget
    },
  }
  const outsideDropdown = {
    open: true,
    contains() {
      return false
    },
  }
  const root = {
    querySelectorAll() {
      return [containingDropdown, outsideDropdown]
    },
  }

  closeDropdownsOutside(root, insideTarget)

  assert.equal(containingDropdown.open, true)
  assert.equal(outsideDropdown.open, false)

  closeDropdownsOutside(root, outsideTarget)

  assert.equal(containingDropdown.open, false)
})
