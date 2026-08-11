module Pages.SelfHost exposing (Model, Msg, page)

import Components.Contact as Contact
import Components.Docs as Docs
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
import Tailwind.Breakpoints exposing (md)
import Tailwind.Theme exposing (buoy, ink, ink_soft, s0, s1, s2, s3, s4, s5, s6, s8, s10)
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
    { title = "Self-host"
    , body =
        [ Ui.pageHero "Self-host"
            "Run Isthmus where your radios and peers live. Start with a Nostr identity for login, then attach MeshCore and Reticulum as you need them."
        , Html.section
            [ classes [ Tw.pt s6, Tw.pb s10 ] ]
            [ Ui.container []
                [ Html.div
                    [ classes
                        [ Tw.grid
                        , Tw.gap s8
                        , md [ Tw.gap s10, Tw.raw "grid-cols-[1.1fr_0.9fr]" ]
                        ]
                    ]
                    [ Ui.prose
                        [ Html.h2 [] [ Html.text "1. Create a Nostr identity" ]
                        , Html.p []
                            [ Html.text "Isthmus signs you in with a Nostr public key ("
                            , Html.code [] [ Html.text "npub" ]
                            , Html.text "). Generate a new key pair in a signer extension — never paste an "
                            , Html.code [] [ Html.text "nsec" ]
                            , Html.text " into the Isthmus web UI."
                            ]
                        , Html.ol []
                            [ Html.li []
                                [ Html.text "Install "
                                , Html.a
                                    [ Attr.href "https://chromewebstore.google.com/detail/aka-profiles/ncmflpbbagcnakkolfpcpogheckolnad"
                                    , Attr.target "_blank"
                                    , Attr.rel "noopener noreferrer"
                                    ]
                                    [ Html.text "AKA Profiles" ]
                                , Html.text " (Chrome / Chromium) — a NIP-07 signer that keeps keys local and supports multiple profiles."
                                ]
                            , Html.li []
                                [ Html.text "Open the extension → create or import a key. Prefer a fresh key for your gateway ops identity if you want it separate from social accounts."
                                ]
                            , Html.li []
                                [ Html.text "Copy your "
                                , Html.code [] [ Html.text "npub" ]
                                , Html.text " (public). You’ll put admin npubs in "
                                , Html.code [] [ Html.text "ISTHMUS_ADMIN_NPUBS" ]
                                , Html.text " later. Keep the "
                                , Html.code [] [ Html.text "nsec" ]
                                , Html.text " only inside the extension (or your offline backup)."
                                ]
                            ]
                        , callout
                            [ Html.p [ classes [ Tw.m s0 ] ]
                                [ Html.text "Other NIP-07 extensions (nos2x, Alby, etc.) work the same way for login. AKA Profiles is a solid default when you want several keys with per-app permissions."
                                ]
                            ]
                        , Html.h2 [] [ Html.text "2. Get the code" ]
                        , Html.p []
                            [ Html.text "The project lives at "
                            , Html.a [ Attr.href "https://github.com/synalysis/isthmus" ]
                                [ Html.text "github.com/synalysis/isthmus" ]
                            , Html.text ". Clone it onto the host that will run the gateway."
                            ]
                        , codeBlock
                            """git clone https://github.com/synalysis/isthmus.git
cd isthmus"""
                        , Html.h2 [] [ Html.text "3. Docker (ops-friendly)" ]
                        , Html.p []
                            [ Html.text "Copy the env template, set secrets and your admin npubs, then bring the stack up. SQLite persists on a volume at "
                            , Html.code [] [ Html.text "/data/isthmus.db" ]
                            , Html.text "."
                            ]
                        , codeBlock
                            """cp .env.example .env
# SECRET_KEY_BASE  → mix phx.gen.secret
# ISTHMUS_VAULT_SECRET → openssl rand -base64 48
# ISTHMUS_ADMIN_NPUBS → npub1...   # from AKA Profiles
docker compose up --build"""
                        , Html.h2 [] [ Html.text "4. Local Mix (development)" ]
                        , Html.p []
                            [ Html.text "For a faster loop on a workstation with Elixir installed:" ]
                        , codeBlock
                            """export ISTHMUS_ADMIN_NPUBS=npub1...
./bin/dev
# open http://localhost:4000"""
                        , Html.h2 [] [ Html.text "5. Log in with AKA Profiles" ]
                        , Html.ol []
                            [ Html.li []
                                [ Html.text "Ensure AKA Profiles is enabled and the profile you want is selected."
                                ]
                            , Html.li []
                                [ Html.text "Open your Isthmus instance and go to "
                                , Html.code [] [ Html.text "/login" ]
                                , Html.text "."
                                ]
                            , Html.li []
                                [ Html.text "Choose sign-in with Nostr / extension. The page talks to "
                                , Html.code [] [ Html.text "window.nostr" ]
                                , Html.text " (NIP-07)."
                                ]
                            , Html.li []
                                [ Html.text "AKA Profiles prompts you to approve "
                                , Html.code [] [ Html.text "getPublicKey" ]
                                , Html.text " and a signed challenge — allow it for this site (once, for a few minutes, or forever)."
                                ]
                            , Html.li []
                                [ Html.text "You’re signed in as that "
                                , Html.code [] [ Html.text "npub" ]
                                , Html.text ". If it’s listed in "
                                , Html.code [] [ Html.text "ISTHMUS_ADMIN_NPUBS" ]
                                , Html.text ", open "
                                , Html.code [] [ Html.text "/admin" ]
                                , Html.text ". Everyone can use "
                                , Html.code [] [ Html.text "/register" ]
                                , Html.text " / "
                                , Html.code [] [ Html.text "/me" ]
                                , Html.text " when policy allows."
                                ]
                            ]
                        , Html.h2 [] [ Html.text "6. Attach MeshCore hardware" ]
                        , Html.p []
                            [ Html.text "On a host with a companion radio ("
                            , Html.a [ Route.Path.href Route.Path.Meshcore ] [ Html.text "MeshCore overview" ]
                            , Html.text "):"
                            ]
                        , Html.ul []
                            [ Html.li []
                                [ Html.text "Detect ports: "
                                , Html.code [] [ Html.text "mix isthmus.meshcore.ports" ]
                                ]
                            , Html.li []
                                [ Html.text "Set "
                                , Html.code [] [ Html.text "ISTHMUS_MESHCORE_TRANSPORT=usb" ]
                                , Html.text " (BLE transport is not implemented yet)"
                                ]
                            , Html.li []
                                [ Html.text "Island bridges need repeater firmware built with "
                                , Html.code [] [ Html.text "WITH_RS232_BRIDGE" ]
                                , Html.text " — see the "
                                , Docs.meshcoreBridgeFirmwareBuild "build and flash guide"
                                ]
                            ]
                        , Html.h2 [] [ Html.text "7. Reticulum / LXMF" ]
                        , Html.p []
                            [ Html.text "Install the sidecar deps ("
                            , Html.code [] [ Html.text "pip install -r sidecar/requirements.txt" ]
                            , Html.text ") so Isthmus runs its own RNS + LXMF stack. LXMF clients such as MeshChatX or Sideband can then send to and receive from your minted destinations. See the "
                            , Html.a [ Route.Path.href Route.Path.Reticulum ] [ Html.text "Reticulum page" ]
                            , Html.text " and the "
                            , Docs.reticulum "Reticulum guide"
                            , Html.text "."
                            ]
                        , callout
                            [ Html.p [ classes [ Tw.m s0, Tw.mb s3 ] ]
                                [ Html.strong [ classes [ Tw.text_simple ink ] ] [ Html.text "About cloud hosts: " ]
                                , Html.text "A Render (or similar) Docker service can host the Phoenix UI and IP-side pieces, but it cannot see a USB companion. Run radio-facing instances on bare metal, a Pi, or an edge box next to the mesh."
                                ]
                            , Html.p [ classes [ Tw.m s0 ] ]
                                [ Html.strong [ classes [ Tw.text_simple ink ] ] [ Html.text "Encryption: " ]
                                , Html.text "Opaque "
                                , Html.strong [] [ Html.text "tunnels" ]
                                , Html.text " keep carried traffic end-to-end encrypted. "
                                , Html.strong [] [ Html.text "Registration and bridge groups" ]
                                , Html.text " must decrypt and re-encrypt to cross protocols — so do not run those gateways on a VPS or other machine you don’t fully control. Prefer hardware you administer."
                                ]
                            ]
                        ]
                    , Html.aside
                        [ classes [ Tw.grid, Tw.gap s6 ] ]
                        [ callout
                            [ Html.strong [ classes [ Tw.text_simple ink ] ] [ Html.text "Checklist" ]
                            , Html.ul [ classes [ Tw.mt s2 ] ]
                                [ Html.li [] [ Html.text "Nostr key in AKA Profiles (or other NIP-07)" ]
                                , Html.li [] [ Html.text "Admin npub allowlist" ]
                                , Html.li [] [ Html.text "Vault + cookie secrets" ]
                                , Html.li [] [ Html.text "Persistent database path" ]
                                , Html.li [] [ Html.text "USB companion port (if RF)" ]
                                , Html.li [] [ Html.text "LXMF reachability for clients (e.g. MeshChatX)" ]
                                ]
                            ]
                        , Html.div []
                            [ Ui.kicker "Network guides"
                            , Html.ul [ classes [ Tw.m s0, Tw.pl s5, Tw.text_simple ink_soft ] ]
                                [ Html.li [] [ Html.a [ Route.Path.href Route.Path.Nostr ] [ Html.text "Nostr" ] ]
                                , Html.li [ classes [ Tw.mt s1 ] ] [ Html.a [ Route.Path.href Route.Path.Meshcore ] [ Html.text "MeshCore" ] ]
                                , Html.li [ classes [ Tw.mt s1 ] ] [ Html.a [ Route.Path.href Route.Path.Reticulum ] [ Html.text "Reticulum" ] ]
                                ]
                            ]
                        , Html.div []
                            [ Ui.kicker "Docs in the repo"
                            , Html.ul [ classes [ Tw.m s0, Tw.pl s5, Tw.text_simple ink_soft ] ]
                                [ Html.li [] [ Docs.registrationAndBridges "Registration and bridges" ]
                                , Html.li [ classes [ Tw.mt s1 ] ] [ Docs.meshcoreIslandBridge "MeshCore island bridge" ]
                                , Html.li [ classes [ Tw.mt s1 ] ] [ Docs.meshcoreBridgeFirmwareBuild "MeshCore bridge firmware build" ]
                                , Html.li [ classes [ Tw.mt s1 ] ] [ Docs.reticulum "Reticulum / LXMF" ]
                                ]
                            ]
                        , Html.div []
                            [ Ui.kicker "Need a hand?"
                            , Contact.view
                            ]
                        ]
                    ]
                ]
            ]
        , Contact.viewBand
        ]
    }


codeBlock : String -> Html msg
codeBlock code =
    Html.pre [] [ Html.code [] [ Html.text code ] ]


callout : List (Html msg) -> Html msg
callout children =
    Html.div
        [ classes
            [ Tw.mt s6
            , Tw.px s5
            , Tw.py s4
            , Tw.border_l_4
            , Tw.border_simple buoy
            , Tw.raw "bg-buoy/10"
            , Tw.text_simple ink_soft
            ]
        ]
        children
