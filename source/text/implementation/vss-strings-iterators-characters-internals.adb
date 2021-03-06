------------------------------------------------------------------------------
--                        M A G I C   R U N T I M E                         --
--                                                                          --
--                       Copyright (C) 2020, AdaCore                        --
--                                                                          --
-- This library is free software;  you can redistribute it and/or modify it --
-- under terms of the  GNU General Public License  as published by the Free --
-- Software  Foundation;  either version 3,  or (at your  option) any later --
-- version. This library is distributed in the hope that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE.                            --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
------------------------------------------------------------------------------

with VSS.Implementation.String_Handlers;

package body VSS.Strings.Iterators.Characters.Internals is

   ---------------------
   -- First_Character --
   ---------------------

   function First_Character
     (Self : Virtual_String'Class)
      return VSS.Strings.Iterators.Characters.Character_Iterator
   is
      use type VSS.Implementation.Strings.String_Handler_Access;

      Handler : constant VSS.Implementation.Strings.String_Handler_Access :=
        Self.Handler;
      Dummy   : Boolean;

   begin
      return Result : VSS.Strings.Iterators.Characters.Character_Iterator do
         Result.Connect (Self'Unrestricted_Access);

         if Handler /= null then
            Handler.Before_First_Character (Self.Data, Result.Position);
            Dummy := Handler.Forward (Self.Data, Result.Position);
         end if;
      end return;
   end First_Character;

end VSS.Strings.Iterators.Characters.Internals;
