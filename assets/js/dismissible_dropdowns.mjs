function closeDropdownsOutside(root, target) {
  root.querySelectorAll("details[data-dropdown][open]").forEach(dropdown => {
    if (!dropdown.contains(target)) dropdown.open = false
  })
}

function installDismissibleDropdowns(root) {
  root.addEventListener("click", event => closeDropdownsOutside(root, event.target))
  root.addEventListener("focusin", event => closeDropdownsOutside(root, event.target))

  root.addEventListener("keydown", event => {
    if (event.key !== "Escape") return

    const dropdown = event.target.closest?.("details[data-dropdown][open]")

    if (dropdown) {
      dropdown.open = false
      dropdown.querySelector("summary")?.focus()
    }
  })
}

export {closeDropdownsOutside, installDismissibleDropdowns}
