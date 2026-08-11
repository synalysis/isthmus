module Pages.Networks exposing (Model, Msg, page)

import Components.Contact as Contact
import Components.Ui as Ui
import Effect exposing (Effect)
import Html
import Html.Attributes as Attr
import Layouts
import Page exposing (Page)
import Route exposing (Route)
import Route.Path
import Shared
import Tailwind as Tw exposing (classes)
import Tailwind.Breakpoints exposing (hover, md)
import Tailwind.Theme exposing (buoy_deep, ink, ink_soft, s0, s2, s2_dot_5, s3, s4, s6, s8, s10, sea, stone)
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
    { title = "Networks"
    , body =
        [ Ui.pageHero "Networks"
            "Three live legs. Pick the stack you know, then see how Isthmus joins it to the others."
        , Html.section
            [ classes [ Tw.pt s6, Tw.pb s10 ] ]
            [ Ui.container []
                [ Html.div
                    [ classes
                        [ Tw.grid
                        , Tw.gap s10
                        , md [ Tw.grid_cols_3, Tw.gap s8 ]
                        ]
                    ]
                    [ protocol "RF mesh"
                        "MeshCore"
                        "Companions, channels, and whole-packet island bridges."
                        Route.Path.Meshcore
                        "https://meshcore.io"
                        "meshcore.io"
                    , protocol "Encrypted mesh"
                        "Reticulum / LXMF"
                        "Isthmus-owned destinations that LXMF clients can message."
                        Route.Path.Reticulum
                        "https://reticulum.network"
                        "reticulum.network"
                    , protocol "Social relays"
                        "Nostr"
                        "NIP-07 login, relay DMs, and admin allowlists by npub."
                        Route.Path.Nostr
                        "https://nostr.com"
                        "nostr.com"
                    ]
                , Html.div [ classes [ Tw.mt s10, Tw.text_simple ink_soft ] ]
                    [ Html.h2
                        [ classes
                            [ Tw.font_display
                            , Tw.font_semibold
                            , Tw.tracking_tight
                            , Tw.text_simple ink
                            , Tw.m s0
                            , Tw.mb s3
                            , Tw.raw "text-[clamp(1.55rem,3vw,1.9rem)]"
                            ]
                        ]
                        [ Html.text "Island bridge vs message gateway" ]
                    , Html.p [ classes [ Tw.m s0, Tw.mb s4, Tw.raw "max-w-[60ch]" ] ]
                        [ Html.text "If you already know MeshCore path discovery, the island bridge is the interesting piece: two RF islands on different frequencies become one mesh because whole "
                        , Html.code [] [ Html.text "mesh::Packet" ]
                        , Html.text " frames cross the tunnel. Those payloads stay end-to-end encrypted between mesh endpoints. The identity gateway and bridge groups are different — they translate messages through Isthmus-owned or attached identities, which means decrypt on the way in and encrypt on the way out. Run that path only on hosts you fully control; a rented VPS can see cleartext at the gateway."
                        ]
                    , Html.p [ classes [ Tw.m s0 ] ]
                        [ Html.a [ Route.Path.href Route.Path.SelfHost ] [ Html.text "Ready to run your own node →" ]
                        ]
                    ]
                ]
            ]
        , Contact.viewBand
        ]
    }


protocol : String -> String -> String -> Route.Path.Path -> String -> String -> Html.Html msg
protocol tag title body path officialHref officialLabel =
    Html.article
        [ classes
            [ Tw.pt s4
            , Tw.border_t_2
            , Tw.border_simple ink
            ]
        ]
        [ Html.span
            [ classes
                [ Tw.inline_block
                , Tw.mb s2_dot_5
                , Tw.text_xs
                , Tw.font_semibold
                , Tw.raw "uppercase tracking-[0.08em]"
                , Tw.text_simple sea
                ]
            ]
            [ Html.text tag ]
        , Html.h3
            [ classes
                [ Tw.font_display
                , Tw.font_semibold
                , Tw.m s0
                , Tw.mb s2
                , Tw.raw "text-[1.6rem] tracking-tight"
                ]
            ]
            [ Html.text title ]
        , Html.p
            [ classes [ Tw.m s0, Tw.mb s3, Tw.text_simple stone ] ]
            [ Html.text body ]
        , Html.p
            [ classes [ Tw.m s0, Tw.mb s3, Tw.text_sm, Tw.text_simple stone ] ]
            [ Html.text "Official site: "
            , Html.a
                [ Attr.href officialHref
                , Attr.target "_blank"
                , Attr.rel "noopener noreferrer"
                ]
                [ Html.text officialLabel ]
            ]
        , Html.a
            [ Route.Path.href path
            , classes
                [ Tw.font_semibold
                , Tw.no_underline
                , Tw.text_simple ink
                , Tw.raw "border-b-2 border-buoy"
                , hover
                    [ Tw.text_simple buoy_deep
                    , Tw.raw "border-buoy-deep"
                    ]
                ]
            ]
            [ Html.text ("About " ++ title ++ " →") ]
        ]
