# Release checklist

- [x] Tag the release
- [ ] Update the ~~old~~ new changelog
- [ ] Tell support

<details>
<summary>Commands</summary>

```bash
git tag -s v2.0 -m "v2.0"
git push origin v2.0
```

</details>

![Release dashboard](./images/dashboard.png "The dashboard")

Questions go to <https://example.com/support> or www.example.com.[^1]

The error budget is $1 - 0.999^n$ over $n$ releases:

$$
B = 1 - \prod_{i=1}^{n} a_i
$$

[^1]: Answered within a working day.
