pin 'application-spree-square', to: 'spree_square/application.js', preload: false

pin_all_from SpreeSquare::Engine.root.join('app/javascript/spree_square/controllers'),
             under: 'spree_square/controllers',
             to:    'spree_square/controllers',
             preload: 'application-spree-square'
