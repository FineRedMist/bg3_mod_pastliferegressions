# Past Life Regressions

Provides a feat and background that grants all class and background tags (excluding Dark Urge). It also has some code to identify when granting inspiration and experience from background events fail (because the background doesn't match) and fixing it.

Note: Selecting the background does not provide skills intentionally: having this background already grants an extraordinary amount of experience.

This functionality is achieved by changing your background to the one expected by the inspiration event, reissuing the grant request, then restoring your background.

Added commands:
* !ListBackgrounds: Lists the backgrounds available
* !SetBackground <characterid> <backgroundid>: Sets the background for the character to the given id. Note: Saving and reloading may be required for the change to have an effect.
