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
            "Isthmus is a self-hosted gateway that connects MeshCore, Meshtastic, Reticulum, and Nostr direct messaging — people keep the clients they already use."
        , Html.section
            [ classes [ Tw.pt s6, Tw.pb s10 ] ]
            [ Ui.container []
                [ Ui.prose
                    [ Html.h2 [] [ Html.text "The idea in plain terms" ]
                    , Html.p []
                        [ Html.text "Someone on MeshCore should be able to DM someone on Nostr. Someone on LXMF should be able to reach a MeshCore contact. A Meshtastic private channel should be able to sit in the same conversation as those nets. Isthmus is the passage: a computer "
                        , Html.strong [] [ Html.text "you" ]
                        , Html.text " run that translates messages so each person stays in the app and radio they already know."
                        ]
                    , Html.p []
                        [ Html.text "It is not a new chat app you migrate everyone into. Direct messages (and, on the radios, group channels) are the product. Optional MeshCore island tunnels exist, but they are not the starting point."
                        ]
                    , callout
                        [ Html.p [ classes [ Tw.m s0, Tw.mb s3 ] ]
                            [ Html.strong [ classes [ Tw.text_simple ink ] ] [ Html.text "Pick what you need." ]
                            ]
                        , Html.ul [ classes [ Tw.m s0, Tw.pl s5 ] ]
                            [ Html.li [] [ Html.text "One identity that should appear on other nets → registration (DMs)" ]
                            , Html.li [] [ Html.text "People who already have accounts, chatting across nets → bridge groups (and radio channels)" ]
                            , Html.li [] [ Html.text "Running and watching the gateway → the web operator UI" ]
                            , Html.li [] [ Html.text "Two MeshCore islands that cannot hear each other → optional tunnels" ]
                            ]
                        ]
                    , Html.h2 [] [ Html.text "Direct messages (registration)" ]
                    , Html.p []
                        [ Html.text "Use registration when "
                        , Html.strong [] [ Html.text "you" ]
                        , Html.text " have a home identity on one network and want Isthmus to create matching stand-ins on the others. Example: you live on Nostr, and the gateway mints a MeshCore contact and a Reticulum address that forward to you — so someone on the radio can DM “you” without knowing how Nostr works."
                        ]
                    , Html.p []
                        [ Html.text "Because the networks encrypt differently, the gateway must decrypt an inbound message and encrypt it again for the outbound network. That is the trade-off for crossing protocol boundaries. Keys for minted proxies live in Isthmus’s vault on your host."
                        ]
                    , Html.p []
                        [ Html.text "Self-service signup (when you enable it) can walk a new person through attaching their primary identity — often with a QR code to hand off radio contact details — without you typing every field by hand. Meshtastic is not on this DM path yet: it joins through channels on a USB companion, not a minted node id."
                        ]
                    , Html.h2 [] [ Html.text "Bridge groups and radio channels" ]
                    , Html.p []
                        [ Html.text "Use a bridge group when everyone "
                        , Html.strong [] [ Html.text "already" ]
                        , Html.text " has working identities and you only need them in the same conversation. You attach real Nostr accounts, MeshCore contacts, and Reticulum destinations. Isthmus does not invent new keys for those people; it fans DMs among the members you attached."
                        ]
                    , Html.p []
                        [ Html.text "On MeshCore and Meshtastic you can also link a "
                        , Html.strong [] [ Html.text "private radio channel" ]
                        , Html.text " (slots 1–7) to the group. Channel traffic fans out to the other nets; replies go back onto each linked radio. Same translation rule: crossing protocols means the gateway sees the clear message long enough to re-encrypt it."
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
                        [ Html.text "If you only care about radio DMs and never touch Nostr social apps, you still use a Nostr key for this admin login — it is the auth method, not a requirement that your community live on Nostr."
                        ]
                    , Html.h2 [] [ Html.text "Encryption and where to run it" ]
                    , Html.p []
                        [ Html.text "Registration, bridge groups, and radio channels cannot stay fully end-to-end across different protocols — the gateway must see plaintext (or equivalent cleartext) to translate. That is why those features belong on machines "
                        , Html.strong [] [ Html.text "you fully control" ]
                        , Html.text ": a home computer, a colo box you administer, or a host next to the radios — not a shared VPS where someone else can read process memory, disks, or logs."
                        ]
                    , Html.p []
                        [ Html.text "MeshCore companions are one RF inbox per USB radio. When several groups share one companion, address traffic with an "
                        , Html.code [] [ Html.text "@token" ]
                        , Html.text " (or rely on last-peer / single-group fallback) so Isthmus knows which conversation you mean."
                        ]
                    , Html.h2 [] [ Html.text "Optional: MeshCore island tunnels" ]
                    , Html.p []
                        [ Html.text "A tunnel joins two MeshCore islands that speak the same protocol but cannot hear each other on the air. Isthmus carries whole packets over another network as the pipe. Message contents stay encrypted between the radios; Isthmus forwards sealed frames. This needs repeater firmware from the Isthmus MeshCore fork — not a stock companion. Do not install an internet tunnel where the MeshCore community does not want one."
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
                        , Html.a [ Route.Path.href Route.Path.Meshtastic ] [ Html.text "Meshtastic" ]
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
