# Charts on a page

Ask for a chart on a page in a [Space](spaces.md) and it lands as a block on that page. A model
decides what to draw, but it never supplies the numbers on its own, so asking needs a text
generation provider and reading a chart later doesn't.

## Ask for a chart

In the [page's prompt](spaces.md#the-pages-prompt), type `/visualize` and what you want, such as
`/visualize turns per week`. The **Chart** kind in the `/` menu starts this for you; in the
terminal client it is **Visualize**, and `g` on a page does the same.

To change a chart, choose **Ask again** on it, or `g` with it selected in the terminal client. The new
chart takes its place, and if no chart can be drawn the old one stays.

## Where the numbers come from

Each chart says where its numbers came from. There are two places:

- **This MC's threads.** Turns per week, thread or project over the last 12 weeks, threads started
  per week, and threads per project. The MC counts these itself. A turn is a message you typed: what
  an agent, a schedule or the MC sent doesn't count, nor do workers, nor the messages a fork copied
  from its source. A thread on another MC in your cluster isn't counted.
- **This page.** The model reads labels and values from the page's text, and every value has to be a
  number written on the page. That shows the number is on the page, not that it belongs to its label,
  so check a chart from a page against the page. The model reads the first 8,000 bytes or so.

If neither can answer, no chart is drawn and you're told why. The first time an MC starts after an
update it may need a minute to read its older threads, and asking for turns then says to try again.
