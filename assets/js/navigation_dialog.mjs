const NavigationDialog = {
  mounted() {
    const dialogId = this.el.dataset.dialogId
    this.returnFocusTo = null
    this.closeFocusTarget = null
    this.desktopViewport = window.matchMedia("(min-width: 64rem)")

    this.dialog = () => document.getElementById(dialogId)

    this.finishClose = () => {
      document.documentElement.classList.remove("overflow-hidden")

      if (this.returnFocusTo) {
        this.returnFocusTo.setAttribute("aria-expanded", "false")
      }

      const focusTarget = this.closeFocusTarget || this.returnFocusTo

      if (focusTarget?.isConnected) {
        focusTarget.focus()
      }

      this.returnFocusTo = null
      this.closeFocusTarget = null
    }

    this.handleClick = event => {
      const opener = event.target.closest("[data-navigation-dialog-open]")

      if (opener?.getAttribute("aria-controls") === dialogId) {
        const dialog = this.dialog()

        if (dialog && !dialog.open) {
          this.returnFocusTo = opener
          opener.setAttribute("aria-expanded", "true")
          document.documentElement.classList.add("overflow-hidden")
          dialog.showModal()
        }

        return
      }

      const dialog = this.dialog()

      if (!dialog?.open) return

      const closeButton = event.target.closest("[data-navigation-dialog-close]")
      const navigationLink = event.target.closest("a[href]")

      if (
        (closeButton && dialog.contains(closeButton)) ||
        (navigationLink && dialog.contains(navigationLink)) ||
        event.target === dialog
      ) {
        dialog.close()
      }
    }

    this.handleClose = event => {
      if (event.target.id === dialogId) this.finishClose()
    }

    this.handleViewportChange = event => {
      const dialog = this.dialog()

      if (event.matches && dialog?.open) {
        this.closeFocusTarget = document.getElementById("main-content")
        dialog.close()
      }
    }

    document.addEventListener("click", this.handleClick)
    document.addEventListener("close", this.handleClose, true)
    this.desktopViewport.addEventListener("change", this.handleViewportChange)
  },

  destroyed() {
    document.removeEventListener("click", this.handleClick)
    document.removeEventListener("close", this.handleClose, true)
    this.desktopViewport.removeEventListener("change", this.handleViewportChange)
    this.finishClose()
  },
}

export default NavigationDialog
