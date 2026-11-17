// @material/material-color-utilities 0.4.0 imports some of its own files without the ".js" ending, which
// Node's module loader rejects. This hook retries such imports with ".js" added. Used only by make-theme.mjs.
import { registerHooks } from 'node:module';
registerHooks({
  resolve(specifier, context, next) {
    try { return next(specifier, context); }
    catch (e) {
      if (e.code === 'ERR_MODULE_NOT_FOUND' && /^\.\.?\//.test(specifier) && !specifier.endsWith('.js')) return next(specifier + '.js', context);
      throw e;
    }
  },
});
