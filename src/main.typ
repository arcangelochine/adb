#import "@preview/bookly:3.1.0": *

#show: bookly.with(
  title: "Advanced Databases",
  author: "AC",
  lang: "en",
  theme: orly,
  colors: (
    primary: rgb(55, 122, 170),
  ),
  title-page: book-title-page(
    series: emph("Notes"),
    subtitle: none,
    institution: none,
    edition: "Draft",
    cover: image("figures/sula.png", width: 100%),
    logo: image("figures/sula_logo.svg"),
  ),
)
