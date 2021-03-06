------------------------------------------------------------------------------
--                        M A G I C   R U N T I M E                         --
--                                                                          --
--                     Copyright (C) 2020-2021, AdaCore                     --
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

with System.Storage_Elements;

limited with VSS.Implementation.String_Handlers;
with VSS.Unicode;

package VSS.Implementation.Strings is

   pragma Preelaborate;

   type Character_Count is range 0 .. 2 ** 30 - 1;
   subtype Character_Index is Character_Count range 1 .. Character_Count'Last;

   type Grapheme_Count is range 0 .. 2 ** 30 - 1;
   subtype Grapheme_Index is Grapheme_Count range 1 .. Grapheme_Count'Last;

   type String_Handler_Access is
     access all
       VSS.Implementation.String_Handlers.Abstract_String_Handler'Class;

   ------------
   -- Cursor --
   ------------

   type Cursor is record
      Index        : Character_Count                   := 0;
      UTF8_Offset  : VSS.Unicode.UTF8_Code_Unit_Index  :=
        VSS.Unicode.UTF8_Code_Unit_Index'Last;
      UTF16_Offset : VSS.Unicode.UTF16_Code_Unit_Index :=
        VSS.Unicode.UTF16_Code_Unit_Index'Last;
   end record;

   -----------------
   -- String_Data --
   -----------------

   --  String_Data is a pair of Handler and pointer to the associated data.
   --  It is not defined how particular implementation of the String_Handler
   --  use pointer.
   --
   --  However, there is one exception: when In_Place Flag is set it means
   --  that special predefined handler is used to process Storage.
   --
   --  Note: data layout is optimized for x86-64 CPU.
   --  Note: Storage has 4 bytes alignment.

   type String_Data (In_Place : Boolean := False) is record
      Capacity : Character_Count := 0;

      Padding  : Boolean := False;
      --  This padding bit is not used in the code, but here for the benefit
      --  of dynamic memory analysis tools such as valgrind.

      case In_Place is
         when True =>
            Storage : System.Storage_Elements.Storage_Array (0 .. 19);

         when False =>
            Handler : String_Handler_Access;
            Pointer : System.Address;
      end case;
   end record;
   for String_Data use record
      Storage  at 0  range  0 .. 159;
      Handler  at 0  range  0 ..  63;
      Pointer  at 8  range  0 ..  63;
      Capacity at 20 range  0 ..  29;
      Padding  at 20 range 30 ..  30;
      In_Place at 20 range 31 ..  31;
   end record;

   overriding function "="
     (Left  : String_Data;
      Right : String_Data) return Boolean;
   --  Compare Left and Right string values.

   pragma Warnings (Off, "aggregate not fully initialized");
   Null_String_Data : constant String_Data := (others => <>);
   pragma Warnings (On, "aggregate not fully initialized");
   --  Data for "null" string. It is used around the code when null string
   --  need to be provided, to avoid compiler's warnings about uninitialized
   --  components. Some components are expected to be not initialized by
   --  default. Also, System.Null_Address is not static expression and can't be
   --  used here for initialization.

   function Is_Empty (Self : String_Data) return Boolean
     with Inline;
   --  Return True when string is empty string: it is ether null or has zero
   --  length.

   function Handler
     (Data : String_Data)
      return VSS.Implementation.Strings.String_Handler_Access
        with Inline;
   --  Return string handler for given string data. Null handler is returned
   --  for null string.

   procedure Reference (Data : in out String_Data) with Inline;
   --  Reference given string data. It is wrapper around Handler and call of
   --  its Reference subprogram when handler is not null.

   procedure Unreference (Data : in out String_Data) with Inline;
   --  Unreference given string data. It is wrapper around Handler and call of
   --  its Unrteference subprogram when handler is not null. Data is set to
   --  "null" value before exit for safety.

end VSS.Implementation.Strings;
