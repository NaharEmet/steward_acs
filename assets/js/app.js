import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}})
liveSocket.connect()
window.liveSocket = liveSocket

const toastLifetime = 5000

const dismissToast = (toast) => {
  if (!toast || toast.classList.contains("is-dismissing")) return

  window.clearTimeout(toast.toastTimeout)
  toast.classList.add("is-dismissing")
  window.setTimeout(() => toast.remove(), 180)
}

const scheduleToast = (toast) => {
  if (!(toast instanceof HTMLElement)) return

  window.clearTimeout(toast.toastTimeout)
  toast.toastTimeout = window.setTimeout(() => {
    const closeButton = toast.querySelector("[data-toast-close]")
    closeButton ? closeButton.click() : dismissToast(toast)
  }, toastLifetime)
}

document.querySelectorAll("[data-toast]").forEach(scheduleToast)

document.addEventListener("click", (event) => {
  const closeButton = event.target instanceof Element
    ? event.target.closest("[data-toast-close]")
    : null

  if (closeButton) dismissToast(closeButton.closest("[data-toast]"))
})

new MutationObserver((mutations) => {
  mutations.forEach((mutation) => {
    if (mutation.type === "attributes") {
      scheduleToast(mutation.target)
      return
    }

    mutation.addedNodes.forEach((node) => {
      if (!(node instanceof Element)) return
      if (node.matches("[data-toast]")) scheduleToast(node)
      node.querySelectorAll("[data-toast]").forEach(scheduleToast)
    })
  })
}).observe(document.body, {
  childList: true,
  subtree: true,
  attributes: true,
  attributeFilter: ["data-toast-message"]
})
