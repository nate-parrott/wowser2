const path = require('path');

module.exports = {
  mode: 'development',
  entry: {
    bundle: './src/index.ts',
    styleSelectors: './src/styleSelectorsStandalone.ts',
  },
  module: {
    rules: [
      {
        test: /\.tsx?$/,
        use: 'ts-loader',
        exclude: /node_modules/,
      },
    ],
  },
  resolve: {
    extensions: ['.tsx', '.ts', '.js'],
  },
  output: {
    filename: '[name].js',
    path: path.resolve(__dirname, 'dist'),
  },
};