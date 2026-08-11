module Components.Ui exposing
    ( btnGhost
    , btnPrimary
    , container
    , kicker
    , officialSite
    , pageHero
    , prose
    , section
    , sectionBand
    , sectionLede
    , sectionTitle
    )

import Html exposing (Html)
import Html.Attributes as Attr
import Tailwind as Tw exposing (classes)
import Tailwind.Breakpoints exposing (hover, md)
import Tailwind.Theme exposing
    ( buoy
    , buoy_deep
    , foam
    , ink
    , ink_soft
    , s0
    , s10
    , s16
    , s2
    , s2_dot_5
    , s3
    , s4
    , s5
    , s6
    , s8
    , stone
    )


container : List (Html.Attribute msg) -> List (Html msg) -> Html msg
container attrs children =
    Html.div
        (classes
            [ Tw.mx_auto
            , Tw.w_full
            , Tw.raw "max-w-[68rem]"
            , Tw.px s4
            , md [ Tw.px s8 ]
            ]
            :: attrs
        )
        children


section : List (Html msg) -> Html msg
section children =
    Html.section
        [ classes
            [ Tw.py s10
            , md [ Tw.py s16 ]
            ]
        ]
        [ container [] children ]


sectionBand : String -> List (Html msg) -> Html msg
sectionBand id_ children =
    Html.section
        [ Attr.id id_
        , classes
            [ Tw.py s10
            , md [ Tw.py s16 ]
            , Tw.bg_simple ink
            , Tw.text_simple foam
            ]
        ]
        [ container [] children ]


pageHero : String -> String -> Html msg
pageHero title lede =
    Html.header
        [ classes
            [ Tw.pt s10
            , md [ Tw.pt s16 ]
            ]
        ]
        [ container []
            [ Html.h1
                [ classes
                    [ Tw.font_display
                    , Tw.font_semibold
                    , Tw.tracking_tight
                    , Tw.text_simple ink
                    , Tw.raw "text-[clamp(2.4rem,6vw,3.6rem)] leading-[1.05] max-w-[14ch] mb-3"
                    ]
                ]
                [ Html.text title ]
            , Html.p
                [ classes
                    [ Tw.text_simple stone
                    , Tw.raw "text-[1.1rem] max-w-[46ch] m-0"
                    ]
                ]
                [ Html.text lede ]
            ]
        ]


officialSite : String -> String -> Html msg
officialSite href label =
    Html.p
        [ classes
            [ Tw.m s0
            , Tw.mb s6
            , Tw.text_sm
            , Tw.text_simple stone
            ]
        ]
        [ Html.text "Official site: "
        , Html.a
            [ Attr.href href
            , Attr.target "_blank"
            , Attr.rel "noopener noreferrer"
            ]
            [ Html.text label ]
        ]


kicker : String -> Html msg
kicker label =
    Html.p
        [ classes
            [ Tw.m s0
            , Tw.mb s2_dot_5
            , Tw.text_xs
            , Tw.font_semibold
            , Tw.raw "uppercase"
            , Tw.tracking_widest
            , Tw.text_simple stone
            ]
        ]
        [ Html.text label ]


sectionTitle : String -> Html msg
sectionTitle title =
    Html.h2
        [ classes
            [ Tw.font_display
            , Tw.font_semibold
            , Tw.tracking_tight
            , Tw.text_simple ink
            , Tw.m s0
            , Tw.mb s3
            , Tw.raw "text-[clamp(2rem,4.5vw,2.85rem)] leading-[1.1] max-w-[18ch]"
            ]
        ]
        [ Html.text title ]


sectionLede : String -> Html msg
sectionLede body =
    Html.p
        [ classes
            [ Tw.m s0
            , Tw.mb s8
            , Tw.text_simple stone
            , Tw.raw "text-[1.08rem] max-w-[48ch]"
            ]
        ]
        [ Html.text body ]


btnPrimary : List (Html.Attribute msg) -> List (Html msg) -> Html msg
btnPrimary attrs children =
    Html.a
        (classes
            [ Tw.inline_flex
            , Tw.items_center
            , Tw.justify_center
            , Tw.gap s2
            , Tw.px s5
            , Tw.py s3
            , Tw.rounded_lg
            , Tw.font_semibold
            , Tw.no_underline
            , Tw.bg_simple buoy
            , Tw.text_simple foam
            , Tw.transition_transform
            , Tw.duration_200
            , hover
                [ Tw.bg_simple buoy_deep
                , Tw.raw "-translate-y-0.5"
                ]
            ]
            :: attrs
        )
        children


btnGhost : List (Html.Attribute msg) -> List (Html msg) -> Html msg
btnGhost attrs children =
    Html.a
        (classes
            [ Tw.inline_flex
            , Tw.items_center
            , Tw.justify_center
            , Tw.gap s2
            , Tw.px s5
            , Tw.py s3
            , Tw.rounded_lg
            , Tw.font_semibold
            , Tw.no_underline
            , Tw.border
            , Tw.border_simple ink
            , Tw.raw "border-opacity-20 bg-foam/70 text-ink"
            , Tw.transition_transform
            , Tw.duration_200
            , hover
                [ Tw.border_simple ink
                , Tw.raw "-translate-y-0.5"
                ]
            ]
            :: attrs
        )
        children


prose : List (Html msg) -> Html msg
prose children =
    Html.div
        [ classes
            [ Tw.raw "prose-isthmus"
            , Tw.text_simple ink_soft
            ]
        ]
        children
