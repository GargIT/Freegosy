/// RomM's platform slugs (IGDB's, in `backend/utils/platform_slugs.py`, plus
/// the hardware variants its player maps to a core) for systems Freegosy
/// already emulates under another slug. Without these, a game on such a
/// platform found no emulator ("No Emulator Configured"), no RetroArch core,
/// save folder or BIOS entry.
///
/// Only systems a listed core actually runs are here. A slug for a system
/// Freegosy has no core for stays unknown.
const Map<String, String> kPlatformSlugAliases = {
  // Nintendo
  'famicom': 'nes',
  'new-style-nes': 'nes',
  'sfam': 'snes',
  'satellaview': 'snes',
  'sufami-turbo': 'snes',
  'super-nintendo-original-european-version': 'snes',
  'super-famicom-shvc-001': 'snes',
  'super-famicom-jr-model-shvc-101': 'snes',
  'new-style-super-nes-model-sns-101': 'snes',
  'ique-player': 'n64',
  'game-boy-pocket': 'gb',
  'game-boy-light': 'gb',
  'game-boy-micro': 'gba',
  'nintendo-ds-lite': 'nds',
  'nintendo-dsi': 'nds',
  'nintendo-dsi-xl': 'nds',
  'pokemon-mini': 'pokemini',
  'g-and-w': 'gameandwatch',
  // Sega
  'sega-mark-iii': 'sms',
  'sega-game-box-9': 'sms',
  'sega-master-system-ii': 'sms',
  'master-system-super-compact': 'sms',
  'master-system-girl': 'sms',
  'sega-mega-drive-2-slash-genesis': 'genesis',
  'sega-mega-jet': 'genesis',
  'mega-pc': 'genesis',
  'tera-drive': 'genesis',
  'sega-nomad': 'genesis',
  // NEC
  'pc-fx': 'pcfx',
  'pc-8800-series': 'pc88',
  'pc-9800-series': 'pc98',
  // SNK
  'neo-geo-cd': 'neogeocd',
  'neo-geo-pocket-color': 'ngpc',
  // Bandai
  'wonderswan-color': 'wonderswancolor',
  'swancrystal': 'wonderswancolor',
  // Atari
  'atari-2600-plus': 'atari2600',
  'atari-lynx-mkii': 'lynx',
  // Commodore
  'commodore-64c': 'c64',
  'c-plus-4': 'plus4',
  'c16': 'plus4',
  'cpet': 'pet',
  'amiga-cd32': 'amiga',
  'commodore-cdtv': 'amiga',
  // Computers
  'zxs': 'zxspectrum',
  'msx2plus': 'msx2',
  'sharp-x68000': 'x68000',
  'thomson-mo5': 'mo5',
  'bbcmicro': 'b2',
  'appleii': 'apple2',
  // Other
  'fairchild-channel-f': 'channelf',
  'odyssey-2': 'odyssey2',
  'videopac-g7400': 'odyssey2',
  'philips-cd-i': 'cdi',
  'tic-80': 'tic80',
  'wasm-4': 'wasm4',
  'uzebox': 'uzem',
};

/// The slug Freegosy knows [slug]'s system by: [slug] itself unless it's one
/// of RomM's names in [kPlatformSlugAliases].
String canonicalPlatformSlug(String slug) => kPlatformSlugAliases[slug] ?? slug;
