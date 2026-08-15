// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/textbin"
import topbar from "../vendor/topbar"

const CopyToClipboard = {
  mounted() {
    this.copy = async () => {
      const label = this.el.querySelector("[data-copy-label]")

      if (!label) return

      try {
        await navigator.clipboard.writeText(this.el.dataset.copyContent)
        label.textContent = "Copied"
        this.el.dataset.copyState = "copied"

        window.setTimeout(() => {
          label.textContent = "Copy"
          delete this.el.dataset.copyState
        }, 1600)
      } catch (_error) {
        label.textContent = "Copy failed"

        window.setTimeout(() => {
          label.textContent = "Copy"
        }, 1600)
      }
    }

    this.el.addEventListener("click", this.copy)
  },

  destroyed() {
    this.el.removeEventListener("click", this.copy)
  },
}

const NavigationDialog = {
  mounted() {
    const dialogId = this.el.dataset.dialogId
    this.returnFocusTo = null
    this.desktopViewport = window.matchMedia("(min-width: 64rem)")

    this.dialog = () => document.getElementById(dialogId)

    this.finishClose = () => {
      document.documentElement.classList.remove("overflow-hidden")

      if (this.returnFocusTo) {
        this.returnFocusTo.setAttribute("aria-expanded", "false")

        if (this.returnFocusTo.isConnected) this.returnFocusTo.focus()
      }

      this.returnFocusTo = null
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

      if (event.matches && dialog?.open) dialog.close()
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

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, CopyToClipboard, NavigationDialog},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
