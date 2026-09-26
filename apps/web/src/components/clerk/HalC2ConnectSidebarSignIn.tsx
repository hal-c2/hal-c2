import { UserButton, useAuth } from "@clerk/react";
import { LogInIcon, ServerIcon, SmartphoneIcon } from "lucide-react";

import { hasCloudPublicConfig } from "../../cloud/publicConfig";
import { SidebarMenu, SidebarMenuButton, SidebarMenuItem } from "../ui/sidebar";
import { MobileClientsUserProfilePage } from "./MobileClientsUserProfilePage";
import { HalC2ConnectUserProfilePage } from "./HalC2ConnectUserProfilePage";
import { useHalC2ConnectAuthPrompt } from "./useHalC2ConnectAuthPrompt";

export function HalC2ConnectSidebarSignIn() {
  if (!hasCloudPublicConfig()) return null;

  return <ConfiguredHalC2ConnectSidebarSignIn />;
}

export function HalC2ConnectSidebarAvatar() {
  if (!hasCloudPublicConfig()) return null;

  return <ConfiguredHalC2ConnectSidebarAvatar />;
}

function ConfiguredHalC2ConnectSidebarAvatar() {
  const { isLoaded, isSignedIn } = useAuth();

  if (!isLoaded || !isSignedIn) return null;

  return (
    <UserButton
      appearance={{
        elements: {
          avatarBox: "size-7",
          userButtonTrigger: "rounded-lg p-1 hover:bg-sidebar-row-hover",
        },
      }}
    >
      <UserButton.UserProfilePage
        label="Mobile clients"
        labelIcon={<SmartphoneIcon className="size-4" />}
        url="mobile-clients"
      >
        <MobileClientsUserProfilePage />
      </UserButton.UserProfilePage>
      <UserButton.UserProfilePage
        label="HAL-C2 Connect"
        labelIcon={<ServerIcon className="size-4" />}
        url="hal-c2-connect"
      >
        <HalC2ConnectUserProfilePage />
      </UserButton.UserProfilePage>
    </UserButton>
  );
}

function ConfiguredHalC2ConnectSidebarSignIn() {
  const { isLoaded, isSignedIn } = useAuth();
  const { authPrompt, openAuthPrompt } = useHalC2ConnectAuthPrompt();

  if (!isLoaded || isSignedIn) return null;

  return (
    <>
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuButton onClick={openAuthPrompt}>
            <LogInIcon />
            <span>Sign in to HAL-C2 Connect</span>
          </SidebarMenuButton>
        </SidebarMenuItem>
      </SidebarMenu>
      {authPrompt}
    </>
  );
}
