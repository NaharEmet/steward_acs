import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const GETTING_STARTED_DISMISSED_KEY = "acs.getting_started_dismissed"
const DASHBOARD_SEEN_KEY = "acs.dashboard_seen"
const MEMBERS_ACCESS_GUIDE_DISMISSED_KEY = "acs.members_access_guide_dismissed"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  params: {
    _csrf_token: csrfToken,
    getting_started_dismissed:
      (localStorage.getItem(GETTING_STARTED_DISMISSED_KEY) === "1" ||
        localStorage.getItem(DASHBOARD_SEEN_KEY) === "1")
        ? "1"
        : "0",
    members_access_guide_dismissed:
      localStorage.getItem(MEMBERS_ACCESS_GUIDE_DISMISSED_KEY) === "1" ? "1" : "0"
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

document.addEventListener("click", async (event) => {
  const trigger = event.target instanceof Element
    ? event.target.closest("[data-copy-target], [data-copy-value]")
    : null
  if (!trigger) return

  const input = trigger.dataset.copyTarget ? document.getElementById(trigger.dataset.copyTarget) : null
  const status = document.getElementById(trigger.dataset.copyStatus)
  const copyValue = trigger.dataset.copyValue || (input ? input.value : null)
  if (!copyValue) return

  const copyManually = (text) => {
    if (input) {
      input.focus()
      input.select()
      if (typeof input.setSelectionRange === "function") {
        input.setSelectionRange(0, text.length)
      }
      return document.execCommand("copy")
    }
    const temp = document.createElement("textarea")
    temp.value = text
    temp.style.position = "fixed"
    temp.style.opacity = "0"
    temp.readOnly = true
    document.body.appendChild(temp)
    temp.select()
    temp.setSelectionRange(0, text.length)
    const result = document.execCommand("copy")
    document.body.removeChild(temp)
    return result
  }

  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(copyValue)
    } else if (!copyManually(copyValue)) {
      throw new Error("Clipboard unavailable")
    }

    trigger.dataset.copyState = "copied"
    trigger.textContent = "Copied"
    if (status) {
      status.textContent = trigger.dataset.copySuccess || "Copied to the clipboard."
    }

    window.setTimeout(() => {
      if (!document.body.contains(trigger)) return
      trigger.dataset.copyState = ""
      trigger.textContent = trigger.dataset.copyLabel || "Copy URL"
    }, 2200)
  } catch (_error) {
    if (input) {
      input.focus()
      input.select()
    }
    if (status) {
      status.textContent = trigger.dataset.copyFallback || "Select the URL and copy it manually."
    }
  }
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
