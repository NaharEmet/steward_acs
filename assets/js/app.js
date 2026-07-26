import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const GETTING_STARTED_DISMISSED_KEY = "acs.getting_started_dismissed"
const DASHBOARD_SEEN_KEY = "acs.dashboard_seen"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  params: {
    _csrf_token: csrfToken,
    getting_started_dismissed:
      (localStorage.getItem(GETTING_STARTED_DISMISSED_KEY) === "1" ||
        localStorage.getItem(DASHBOARD_SEEN_KEY) === "1")
        ? "1"
        : "0"
  }
})
liveSocket.connect()
window.liveSocket = liveSocket

window.addEventListener("phx:store", (event) => {
  const {key, value} = event.detail || {}
  if (typeof key === "string" && typeof value === "string") {
    localStorage.setItem(key, value)
  }
})

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
