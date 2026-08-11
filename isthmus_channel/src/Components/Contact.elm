module Components.Contact exposing (view, viewBand)

import Components.Ui as Ui
import Html exposing (Html)
import Html.Attributes as Attr
import Tailwind as Tw exposing (classes)
import Tailwind.Breakpoints exposing (hover)
import Tailwind.Theme exposing (buoy_deep, foam, ink, s0, s1, s2, s3, s8, sea_mist, stone)


email : String
email =
    "hello@isthmus.channel"


npub : String
npub =
    "npub1sthmus7ltsyk9c6rdyuaga32jdr868u4qg2lmfjg3dl3g597ctdqa0uudg"


view : Html msg
view =
    Html.div
        [ classes [ Tw.grid, Tw.gap s3 ] ]
        [ contactRow "Email" ("mailto:" ++ email) email False
        , contactRow "Nostr" ("https://njump.me/" ++ npub) npub False
        ]


viewBand : Html msg
viewBand =
    Ui.sectionBand "contact"
        [ Html.p
            [ classes
                [ Tw.m s0
                , Tw.mb s2
                , Tw.text_xs
                , Tw.font_semibold
                , Tw.raw "uppercase"
                , Tw.tracking_widest
                , Tw.text_simple sea_mist
                ]
            ]
            [ Html.text "Contact" ]
        , Html.h2
            [ classes
                [ Tw.font_display
                , Tw.font_semibold
                , Tw.tracking_tight
                , Tw.text_simple foam
                , Tw.m s0
                , Tw.mb s3
                , Tw.raw "text-[clamp(2rem,4.5vw,2.85rem)] leading-[1.1] max-w-[18ch]"
                ]
            ]
            [ Html.text "Reach the channel" ]
        , Html.p
            [ classes
                [ Tw.m s0
                , Tw.mb s8
                , Tw.text_simple sea_mist
                , Tw.raw "text-[1.08rem] max-w-[48ch]"
                ]
            ]
            [ Html.text "Questions about bridging, firmware, or a self-hosted setup — write by email or Nostr DM." ]
        , Html.div
            [ classes [ Tw.grid, Tw.gap s3 ] ]
            [ contactRow "Email" ("mailto:" ++ email) email True
            , contactRow "Nostr" ("https://njump.me/" ++ npub) npub True
            ]
        ]


contactRow : String -> String -> String -> Bool -> Html msg
contactRow label href value onBand =
    Html.div [ classes [ Tw.grid, Tw.gap s1 ] ]
        [ Html.span
            [ classes
                [ Tw.text_xs
                , Tw.font_semibold
                , Tw.raw "uppercase"
                , Tw.tracking_widest
                , if onBand then
                    Tw.text_simple sea_mist

                  else
                    Tw.text_simple stone
                ]
            ]
            [ Html.text label ]
        , Html.a
            [ Attr.href href
            , classes
                [ Tw.font_display
                , Tw.font_medium
                , Tw.no_underline
                , Tw.raw "text-[1.15rem] break-all"
                , if onBand then
                    Tw.text_simple foam

                  else
                    Tw.text_simple ink
                , hover [ Tw.text_simple buoy_deep ]
                ]
            ]
            [ Html.text value ]
        ]
