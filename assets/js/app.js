import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/isthmus"
import topbar from "../vendor/topbar"

const NostrLogin = {
  mounted() {
    this.el.querySelector("[data-nostr-login]")?.addEventListener("click", () => this.login())
    this.handleEvent("nostr_login_token", ({token}) => {
      const input = document.getElementById("nostr-session-token")
      const form = document.getElementById("nostr-session-form")
      if (input && form && token) {
        input.value = token
        form.submit()
      }
    })
  },
  updated() {
    // challenge text may refresh
  },
  async login() {
    const status = document.getElementById("nostr-login-status")
    const setStatus = (msg) => {
      if (status) status.textContent = msg
    }

    if (!window.nostr || typeof window.nostr.signEvent !== "function") {
      setStatus("No NIP-07 extension detected. Install Alby or nos2x.")
      return
    }

    try {
      setStatus("Requesting public key…")
      const pubkey = await window.nostr.getPublicKey()
      const challenge = this.el.dataset.challenge
      const event = {
        kind: 27235,
        created_at: Math.floor(Date.now() / 1000),
        tags: [["u", window.location.origin], ["method", "LOGIN"]],
        content: challenge,
        pubkey
      }

      setStatus("Waiting for signature…")
      const signed = await window.nostr.signEvent(event)
      this.pushEvent("nostr_signed", {event: signed})
      setStatus("Verifying…")
    } catch (err) {
      setStatus(err?.message || String(err))
    }
  }
}

const pad2 = (n) => String(n).padStart(2, "0")

const LocalTime = {
  mounted() {
    this.renderLocal()
  },
  updated() {
    this.renderLocal()
  },
  renderLocal() {
    const iso = this.el.dataset.utc
    if (!iso) return
    const d = new Date(iso)
    if (Number.isNaN(d.getTime())) return
    this.el.textContent =
      `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}` +
      ` ${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone},
  hooks: {...colocatedHooks, NostrLogin, LocalTime},
})

topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
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
