module Pages.Home_ exposing (Model, Msg, page)

import Components.Contact as Contact
import Components.HeroCanvas as HeroCanvas
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
import Tailwind.Theme exposing
    ( buoy_deep
    , ink
    , ink_soft
    , s0
    , s10
    , s16
    , s2
    , s3
    , s4
    , s6
    , s8
    , stone
    )
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



-- INIT


type alias Model =
    {}


init : () -> ( Model, Effect Msg )
init () =
    ( {}
    , Effect.none
    )



-- UPDATE


type Msg
    = NoOp


update : Msg -> Model -> ( Model, Effect Msg )
update msg model =
    case msg of
        NoOp ->
            ( model
            , Effect.none
            )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none



-- VIEW


view : Model -> View Msg
view _ =
    { title = "Bridge the nets you already use"
    , body =
        [ Html.section
            [ Attr.attribute "aria-label" "Introduction"
            , classes
                [ Tw.relative
                , Tw.grid
                , Tw.items_end
                , Tw.overflow_hidden
                , Tw.raw "min-h-[calc(100svh-4.25rem)] isolate"
                ]
            ]
            [ HeroCanvas.view
            , Html.div
                [ classes
                    [ Tw.raw "w-[min(100%-2rem,40rem)] ml-[max(1rem,calc((100%-68rem)/2))] mr-auto"
                    , Tw.px s4
                    , Tw.py s10
                    , md [ Tw.py s16, Tw.px s0 ]
                    ]
                ]
                [ Html.h1
                    [ Attr.class "rise-in"
                    , classes
                        [ Tw.font_display
                        , Tw.font_bold
                        , Tw.tracking_tight
                        , Tw.text_simple ink
                        , Tw.m s0
                        , Tw.mb s4
                        , Tw.raw "text-[clamp(3.6rem,10vw,6.4rem)] leading-[0.92] tracking-[-0.04em]"
                        ]
                    ]
                    [ Html.text "Isthmus" ]
                , Html.p
                    [ Attr.class "rise-in rise-in-delay-1"
                    , classes
                        [ Tw.font_display
                        , Tw.font_medium
                        , Tw.tracking_tight
                        , Tw.m s0
                        , Tw.mb s3
                        , Tw.raw "text-[clamp(1.45rem,3.2vw,2rem)] leading-snug max-w-[22ch]"
                        ]
                    ]
                    [ Html.text "A narrow passage between mesh islands." ]
                , Html.p
                    [ Attr.class "rise-in rise-in-delay-2"
                    , classes
                        [ Tw.m s0
                        , Tw.mb s8
                        , Tw.text_simple ink_soft
                        , Tw.raw "text-[1.08rem] max-w-[36ch]"
                        ]
                    ]
                    [ Html.text "Self-host a gateway that tunnels and translates across MeshCore, Reticulum, and Nostr — so the net you know can reach the ones you don't." ]
                , Html.div
                    [ Attr.class "rise-in rise-in-delay-3"
                    , classes [ Tw.flex, Tw.flex_wrap, Tw.gap s3 ]
                    ]
                    [ Ui.btnPrimary [ Route.Path.href Route.Path.SelfHost ] [ Html.text "Self-host guide" ]
                    , Ui.btnGhost [ Route.Path.href Route.Path.HowItWorks ] [ Html.text "How it works" ]
                    ]
                ]
            ]
        , Ui.section
            [ Ui.kicker "For protocol people"
            , Ui.sectionTitle "You already speak one of these."
            , Ui.sectionLede "Isthmus is for operators who live on MeshCore, Reticulum/LXMF, or Nostr and want a reliable bridge — not another siloed chat app."
            , Html.div
                [ classes
                    [ Tw.grid
                    , Tw.gap s6
                    , Tw.border_t
                    , Tw.raw "border-ink/15"
                    , Tw.pt s6
                    , md [ Tw.grid_cols_3, Tw.gap s8 ]
                    ]
                ]
                [ teaser "How it works"
                    "Tunnels carry opaque packets. The identity gateway mints proxies or fans out among real attachments."
                    Route.Path.HowItWorks
                    "Read the model"
                    , teaser "Networks"
                        "MeshCore, Reticulum, and Nostr — dedicated guides for each leg of the bridge."
                        Route.Path.Networks
                        "Explore networks"
                , teaser "Self-host"
                    "Docker or Mix on a host that can see your radios. USB companions stay on the metal."
                    Route.Path.SelfHost
                    "Start hosting"
                ]
            ]
        , Contact.viewBand
        ]
    }


teaser : String -> String -> Route.Path.Path -> String -> Html.Html msg
teaser title body path linkLabel =
    Html.article []
        [ Html.h3
            [ classes
                [ Tw.font_display
                , Tw.font_semibold
                , Tw.m s0
                , Tw.mb s2
                , Tw.raw "text-[1.35rem]"
                ]
            ]
            [ Html.text title ]
        , Html.p
            [ classes
                [ Tw.m s0
                , Tw.mb s3
                , Tw.text_simple stone
                ]
            ]
            [ Html.text body ]
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
            [ Html.text linkLabel ]
        ]
