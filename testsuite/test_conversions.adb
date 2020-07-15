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

with Ada.Strings.UTF_Encoding;

with VSS.Strings.Conversions;

with Hello_World_Data;

procedure Test_Conversions is
begin
   --  Check conversion of "Hello, world!" in different languages. It is known
   --  all strings are well-formed, there should be no exceptions. Note, it is
   --  sanity check, it doesn't cover all cases of UTF-8 validation.

   for Language in Hello_World_Data.Language'Range loop
      declare
         String : VSS.Strings.Virtual_String;

      begin
         String :=
           VSS.Strings.Conversions.To_Magic_String
             (Hello_World_Data.Hello (Language));

         if VSS.Strings.Conversions.To_UTF_8_String (String)
           /= Hello_World_Data.Hello (Language)
         then
            raise Program_Error;
         end if;
      end;
   end loop;

   --  Check conversion of one character of each representation length in
   --  UTF-8. First string is quite short and may fit to be stored in-place
   --  while second one is large enought to be stored by handler with
   --  allocation.
   --
   --  More cases may need to be added to cover other configurations of string
   --  handlers.

   declare
      S1 : constant VSS.Strings.Virtual_String :=
        VSS.Strings.To_Virtual_String ("AБक𐌈");
      S2 : constant VSS.Strings.Virtual_String :=
        VSS.Strings.To_Virtual_String ("AБक𐌈𐌈कБA");
      E1 : constant Ada.Strings.UTF_Encoding.UTF_8_String :=
        (1  => Character'Val (16#41#),
         2  => Character'Val (16#D0#),
         3  => Character'Val (16#91#),
         4  => Character'Val (16#E0#),
         5  => Character'Val (16#A4#),
         6  => Character'Val (16#95#),
         7  => Character'Val (16#F0#),
         8  => Character'Val (16#90#),
         9  => Character'Val (16#8C#),
         10 => Character'Val (16#88#));
      E2 : constant Ada.Strings.UTF_Encoding.UTF_8_String :=
        (1  => Character'Val (16#41#),
         2  => Character'Val (16#D0#),
         3  => Character'Val (16#91#),
         4  => Character'Val (16#E0#),
         5  => Character'Val (16#A4#),
         6  => Character'Val (16#95#),
         7  => Character'Val (16#F0#),
         8  => Character'Val (16#90#),
         9  => Character'Val (16#8C#),
         10 => Character'Val (16#88#),
         11 => Character'Val (16#F0#),
         12 => Character'Val (16#90#),
         13 => Character'Val (16#8C#),
         14 => Character'Val (16#88#),
         15 => Character'Val (16#E0#),
         16 => Character'Val (16#A4#),
         17 => Character'Val (16#95#),
         18 => Character'Val (16#D0#),
         19 => Character'Val (16#91#),
         20 => Character'Val (16#41#));

   begin
      if VSS.Strings.Conversions.To_UTF_8_String (S1) /= E1 then
         raise Program_Error;
      end if;

      if VSS.Strings.Conversions.To_UTF_8_String (S2) /= E2 then
         raise Program_Error;
      end if;
   end;
end Test_Conversions;
