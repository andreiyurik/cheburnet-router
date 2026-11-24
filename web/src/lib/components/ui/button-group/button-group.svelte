<script module>
	import { cn } from "$lib/utils.js";

	const BUTTON_GROUP_VARIANTS = {
  "orientation": {
    "horizontal": "[&>*:not(:first-child)]:rounded-s-none [&>*:not(:first-child)]:border-s-0 [&>*:not(:last-child)]:rounded-e-none",
    "vertical": "flex-col [&>*:not(:first-child)]:rounded-t-none [&>*:not(:first-child)]:border-t-0 [&>*:not(:last-child)]:rounded-b-none"
  }
};
// width — вариантом, а не классом: без tailwind-merge w-full не перебивает w-fit надёжно.
const BUTTON_GROUP_WIDTH = { fit: "w-fit", full: "w-full [&>*]:flex-1" };
export const buttonGroupVariants = ({ orientation = "horizontal", width = "fit" } = {}) =>
  cn(BUTTON_GROUP_WIDTH[width], "flex items-stretch has-[>[data-slot=button-group]]:gap-2 [&>*]:focus-visible:relative [&>*]:focus-visible:z-10 has-[select[aria-hidden=true]:last-child]:[&>[data-slot=select-trigger]:last-of-type]:rounded-e-md [&>[data-slot=select-trigger]:not([class*='w-'])]:w-fit [&>input]:flex-1", BUTTON_GROUP_VARIANTS.orientation[orientation]);
</script>

<script>

	let {
		ref = $bindable(null),
		class: className,
		children,
		orientation = "horizontal",
		width = "fit",
		...restProps
	} = $props();
</script>

<div
	bind:this={ref}
	role="group"
	data-slot="button-group"
	data-orientation={orientation}
	class={cn(buttonGroupVariants({ orientation, width }), className)}
	{...restProps}
>
	{@render children?.()}
</div>
