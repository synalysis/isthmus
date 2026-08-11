module Pages.HowItWorks exposing (Model, Msg, page)

import Components.Contact as Contact
import Components.Ui as Ui
import Effect exposing (Effect)
import Html exposing (Html)
import Html.Attributes as Attr
import Layouts
import Page exposing (Page)
import Route exposing (Route)
import Route.Path
import Shared
import Tailwind as Tw exposing (classes)
import Tailwind.Theme exposing (buoy, ink, ink_soft, s0, s3, s4, s5, s6, s10)
import View exposing (View)


page : Shared.Model -> Route () -> Page Model Msg
page _ _ =
    Page.new
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        }
        |> Page.withLayout toLayout


toLayout : Model -> Layouts.Layout Msg
toLayout _ =
    Layouts.Default {}


type alias Model =
    {}


init : () -> ( Model, Effect Msg )
init () =
    ( {}, Effect.none )


type Msg
    = NoOp


update : Msg -> Model -> ( Model, Effect Msg )
update msg model =
    case msg of
        NoOp ->
            ( model, Effect.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none


view : Model -> View Msg
view _ =
    { title = "How it works"
    , body =
        [ Ui.pageHero "How it works"
            "Isthmus is a self-hosted gateway that can tunnel traffic between mesh islands and translate messages across MeshCore, Reticulum, and Nostr."
        , Html.section
            [ classes [ Tw.pt s6, Tw.pb s10 ] ]
            [ Ui.container []
                [ Ui.prose
                    [ Html.h2 [] [ Html.text "The idea in plain terms" ]
                    , Html.p []
                        [ Html.text "Think of three kinds of network that normally stay apart: radios talking MeshCore, encrypted Reticulum/LXMF peers, and Nostr apps that store notes and messages on relays. Isthmus sits where those worlds can meet — on a computer "
                        , Html.strong [] [ Html.text "you" ]
                        , Html.text " run — and either carries packets unchanged or rewrites messages so they can be delivered on another network."
                        ]
                    , Html.p []
                        [ Html.text "It is not a new chat app you migrate everyone into. People keep using the clients and radios they already know. Isthmus is the passage in between."
                        ]
                    , callout
                        [ Html.p [ classes [ Tw.m s0, Tw.mb s3 ] ]
                            [ Html.strong [ classes [ Tw.text_simple ink ] ] [ Html.text "Pick what you need." ]
                            ]
                        , Html.ul [ classes [ Tw.m s0, Tw.pl s5 ] ]
                            [ Html.li [] [ Html.text "Same protocol, far apart → tunnels" ]
                            , Html.li [] [ Html.text "One identity that should appear on other nets → registration" ]
                            , Html.li [] [ Html.text "People who already have accounts, chatting across nets → bridge groups" ]
                            , Html.li [] [ Html.text "Running and watching the gateway → the web operator UI" ]
                            ]
                        ]
                    , Html.h2 [] [ Html.text "Transport tunnels" ]
                    , Html.p []
                        [ Html.text "Use a tunnel when two groups speak the "
                        , Html.strong [] [ Html.text "same" ]
                        , Html.text " protocol but cannot hear each other on the air — for example two MeshCore islands separated by distance or geography. Isthmus carries their packets over another network as the pipe (often the internet or Reticulum)."
                        ]
                    , Html.p []
                        [ Html.text "For MeshCore island bridges, whole packets are replayed: discovery, acknowledgements, and direct messages included. Nodes on the far island show up as ordinary mesh neighbours. The message contents stay encrypted between the radios that own them; Isthmus forwards sealed frames and does not need to open them."
                        ]
                    , Html.p []
                        [ Html.text "Tunnels need the right firmware and setup on the radio side (bridge-capable MeshCore firmware, not a stock companion-only build). Do not install an internet tunnel where the MeshCore community does not want one."
                        ]
                    , Html.h2 [] [ Html.text "Identity gateway (registration)" ]
                    , Html.p []
                        [ Html.text "Use registration when "
                        , Html.strong [] [ Html.text "you" ]
                        , Html.text " have a home identity on one network and want Isthmus to create matching stand-ins on the others. Example: you live on Nostr, and the gateway mints a MeshCore contact and a Reticulum address that forward to you — so someone on the radio can reach “you” without knowing how Nostr works."
                        ]
                    , Html.p []
                        [ Html.text "Because the networks encrypt differently, the gateway must decrypt an inbound message and encrypt it again for the outbound network. That is the trade-off for crossing protocol boundaries. Keys for minted proxies live in Isthmus’s vault on your host."
                        ]
                    , Html.p []
                        [ Html.text "Self-service signup (when you enable it) can walk a new person through attaching their primary identity — often with a QR code to hand off radio contact details — without you typing every field by hand."
                        ]
                    , Html.h2 [] [ Html.text "Bridge groups" ]
                    , Html.p []
                        [ Html.text "Use a bridge group when everyone "
                        , Html.strong [] [ Html.text "already" ]
                        , Html.text " has working identities and you only need them in the same conversation across networks. You attach real Nostr accounts, MeshCore contacts, and Reticulum destinations. Isthmus does not invent new keys for those people; it fans messages among the members you attached."
                        ]
                    , Html.p []
                        [ Html.text "Same translation rule as registration: crossing protocols means the gateway sees the clear message long enough to re-encrypt it for each other network."
                        ]
                    , Html.h2 [] [ Html.text "Signing in and the operator UI" ]
                    , Html.p []
                        [ Html.text "Day-to-day, you manage Isthmus in a browser: health of the radios and links, who is registered, group membership, relays, and a log of what got forwarded. Under the hood that UI is a Phoenix (Elixir) app you host yourself."
                        ]
                    , Html.p []
                        [ Html.text "Login uses "
                        , Html.strong [] [ Html.text "Nostr" ]
                        , Html.text " — not a password Isthmus stores. In short: you (or each admin) have a cryptographic key pair. The "
                        , Html.strong [] [ Html.text "public" ]
                        , Html.text " half identifies you (shown as an "
                        , Html.code [] [ Html.text "npub…" ]
                        , Html.text " string). The "
                        , Html.strong [] [ Html.text "private" ]
                        , Html.text " half stays in a browser extension that can sign challenges so Isthmus knows it is really you. That extension pattern is what the Nostr world calls "
                        , Html.strong [] [ Html.text "NIP-07" ]
                        , Html.text " — a small standard that says “ask the user’s local signer,” the same idea as a password manager that never pastes the secret into the site."
                        ]
                    , Html.p []
                        [ Html.text "You do not need to be a Nostr power user. Install a signer extension (the self-host guide recommends "
                        , Html.a
                            [ Attr.href "https://chromewebstore.google.com/detail/aka-profiles/ncmflpbbagcnakkolfpcpogheckolnad"
                            , Attr.target "_blank"
                            , Attr.rel "noopener noreferrer"
                            ]
                            [ Html.text "AKA Profiles" ]
                        , Html.text "), create or import a key, and allow Isthmus to request a signature when you log in. Never paste a private key ("
                        , Html.code [] [ Html.text "nsec" ]
                        , Html.text ") into Isthmus. Admins are listed by their public "
                        , Html.code [] [ Html.text "npub" ]
                        , Html.text " in config."
                        ]
                    , Html.p []
                        [ Html.text "If you only care about MeshCore tunnels and never touch Nostr social apps, you still use a Nostr key for this admin login — it is the auth method, not a requirement that your community live on Nostr."
                        ]
                    , Html.h2 [] [ Html.text "Encryption and where to run it" ]
                    , Html.p []
                        [ Html.text "Tunnels preserve end-to-end encryption for the traffic they carry: Isthmus is a sealed pipe. Registration and bridge groups cannot stay fully end-to-end across different protocols — the gateway must see plaintext (or equivalent cleartext) to translate. That is why those features belong on machines "
                        , Html.strong [] [ Html.text "you fully control" ]
                        , Html.text ": a home computer, a colo box you administer, or a host next to the radios — not a shared VPS where someone else can read process memory, disks, or logs."
                        ]
                    , Html.p []
                        [ Html.text "MeshCore companions are one RF inbox per USB radio. When several groups share one companion, address traffic with an "
                        , Html.code [] [ Html.text "@token" ]
                        , Html.text " (or rely on last-peer / single-group fallback) so Isthmus knows which conversation you mean."
                        ]
                    , Html.h2 [] [ Html.text "What to read next" ]
                    , Html.p []
                        [ Html.text "Start from the network you already use, or jump straight to hosting."
                        ]
                    , Html.p []
                        [ Html.a [ Route.Path.href Route.Path.Networks ] [ Html.text "Networks overview" ]
                        , Html.text " · "
                        , Html.a [ Route.Path.href Route.Path.Meshcore ] [ Html.text "MeshCore" ]
                        , Html.text " · "
                        , Html.a [ Route.Path.href Route.Path.Reticulum ] [ Html.text "Reticulum" ]
                        , Html.text " · "
                        , Html.a [ Route.Path.href Route.Path.Nostr ] [ Html.text "Nostr" ]
                        , Html.text " · "
                        , Html.a [ Route.Path.href Route.Path.SelfHost ] [ Html.text "Self-host guide" ]
                        ]
                    ]
                ]
            ]
        , Contact.viewBand
        ]
    }


callout : List (Html msg) -> Html msg
callout children =
    Html.div
        [ classes
            [ Tw.mt s6
            , Tw.mb s3
            , Tw.px s5
            , Tw.py s4
            , Tw.border_l_4
            , Tw.border_simple buoy
            , Tw.raw "bg-buoy/10"
            , Tw.text_simple ink_soft
            ]
        ]
        children
