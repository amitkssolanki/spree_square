# Contributing

Thanks for considering a contribution to `spree_square`.

## Getting set up

```bash
bundle install
bundle exec rake test_app   # generates spec/dummy, the Rails app specs run against
bundle exec rspec
```

## Making a change

1. Open an issue first for anything beyond a small fix, so the approach can be discussed before
   you put time into it.
2. Add or update specs alongside any behavior change — `bundle exec rspec` should stay green.
3. Keep decorators as a last resort (see the main README's customization pattern order); prefer
   Spree's Events/Subscribers or Dependencies mechanisms where they fit.
4. Open a pull request describing what changed and why.

## Releasing (maintainers)

```bash
bundle exec gem bump --version [major|minor|patch] -t -m "Release v%s"
bundle exec gem release
```

See the [gem-release README](https://github.com/svenfuchs/gem-release) for more options.
